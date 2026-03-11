#include <chrono>
#include <jni.h>
#include <map>
#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/stitching.hpp>
#include <string>
#include <vector>

using namespace cv;
using namespace std;

// CONFIG: Single place to adjust capture distance
// 0.5 = 50% overlap between adjacent photos
// Higher = closer photos. Lower = photos further apart.
const double TARGET_OVERLAP = 0.1;

// Struct to explicitly store frame metadata for grid-aware stitching
struct CapturedFrame {
  Mat image;
  int row;
  int col;
};

std::string getExcelColumnName(int col) {
  if (col <= 0)
    return "X";
  std::string name = "";
  while (col > 0) {
    int mod = (col - 1) % 26;
    name = (char)('A' + mod) + name;
    col = (col - mod) / 26;
  }
  return name;
}

// In-memory store of captured RGB frames with grid coordinates
std::vector<CapturedFrame> capturedFrames;
std::vector<Point2f> capturedPositions;

// Downsampled previous frame for fast FAST/ORB tracking
Mat previousFrameDownscaled;
double tracking_x = 0.0;
double tracking_y = 0.0;
int64_t hold_start_ms = 0;

extern "C" JNIEXPORT void JNICALL
Java_com_example_shelf_1scanner_MainActivity_startScanNative(
    JNIEnv *env, jobject /* this */) {
  capturedFrames.clear();
  capturedPositions.clear();
  previousFrameDownscaled.release();
  tracking_x = 0.0;
  tracking_y = 0.0;
  hold_start_ms = 0;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_example_shelf_1scanner_MainActivity_processFrameNative(
    JNIEnv *env, jobject /* this */, jbyteArray yuvBytes, jint width,
    jint height, jint rowStride, jboolean allowRight, jboolean allowDown,
    jboolean allowUp, jint gridX, jint gridY, jboolean forceCapture) {

  jbyte *bytes = env->GetByteArrayElements(yuvBytes, nullptr);
  Mat yuv(height + height / 2, width, CV_8UC1, (unsigned char *)bytes);
  Mat bgrFrame;
  cvtColor(yuv, bgrFrame, COLOR_YUV2BGR_NV12);
  env->ReleaseByteArrayElements(yuvBytes, bytes, JNI_ABORT);
  rotate(bgrFrame, bgrFrame, ROTATE_90_CLOCKWISE);

  Mat downscaledTarget;
  resize(bgrFrame, downscaledTarget, Size(), 0.5, 0.5);

  Mat grayFrame;
  cvtColor(downscaledTarget, grayFrame, COLOR_BGR2GRAY);

  double min_dim = std::min(downscaledTarget.cols, downscaledTarget.rows);

  // STRIDE = (1.0 - OVERLAP) * FrameWidth
  // If overlap is 50% (0.5), we move 50% of the width before capturing next.
  // Note: Using min_dim because tracking happens in the downscaled (0.5x)
  // space.
  double strideRatio = 1.0 - TARGET_OVERLAP;
  double overlapRatioTrigger = min_dim * strideRatio;

  if (previousFrameDownscaled.empty()) {
    previousFrameDownscaled = grayFrame.clone();

    // Crop frame to match the center "Capture Box" UI (8% padding on all sides)
    int cropX = bgrFrame.cols * 0.08;
    int cropY = bgrFrame.rows * 0.08;
    int cropW = bgrFrame.cols - 2 * cropX;
    int cropH = bgrFrame.rows - 2 * cropY;
    Mat cropped = bgrFrame(Rect(cropX, cropY, cropW, cropH)).clone();

    capturedFrames.push_back({cropped, gridY, gridX});
    capturedPositions.push_back(Point2f(0.0f, 0.0f));
    tracking_x = 0.0;
    tracking_y = 0.0;

    jdoubleArray result = env->NewDoubleArray(6);
    jdouble values[6] = {1.0, 0.0, 0.0, overlapRatioTrigger, 0.0, 0.0};
    env->SetDoubleArrayRegion(result, 0, 6, values);
    return result;
  }

  Ptr<ORB> orb = ORB::create();
  vector<KeyPoint> keypoints1, keypoints2;
  Mat descriptors1, descriptors2;

  orb->detectAndCompute(previousFrameDownscaled, noArray(), keypoints1,
                        descriptors1);
  orb->detectAndCompute(grayFrame, noArray(), keypoints2, descriptors2);

  if (descriptors1.empty() || descriptors2.empty()) {
    previousFrameDownscaled = grayFrame.clone();
    Point2f last_pos = capturedPositions.back();
    double dx_from_last = tracking_x - last_pos.x;
    double dy_from_last = tracking_y - last_pos.y;
    jdoubleArray result = env->NewDoubleArray(6);
    jdouble values[6] = {0.0, dx_from_last, dy_from_last, overlapRatioTrigger,
                         0.0, 0.0};
    env->SetDoubleArrayRegion(result, 0, 6, values);
    return result;
  }

  BFMatcher matcher(NORM_HAMMING);
  vector<DMatch> matches;
  matcher.match(descriptors1, descriptors2, matches);

  if (matches.size() >= 10) {
    vector<double> x_diffs, y_diffs;
    for (size_t i = 0; i < matches.size(); i++) {
      Point2f pt1 = keypoints1[matches[i].queryIdx].pt;
      Point2f pt2 = keypoints2[matches[i].trainIdx].pt;
      x_diffs.push_back(pt1.x - pt2.x);
      y_diffs.push_back(pt1.y - pt2.y);
    }
    std::nth_element(x_diffs.begin(), x_diffs.begin() + x_diffs.size() / 2,
                     x_diffs.end());
    std::nth_element(y_diffs.begin(), y_diffs.begin() + y_diffs.size() / 2,
                     y_diffs.end());
    tracking_x += x_diffs[x_diffs.size() / 2];
    tracking_y += y_diffs[y_diffs.size() / 2];
  }

  previousFrameDownscaled = grayFrame.clone();

  Point2f last_pos = capturedPositions.back();
  double dx_from_last = tracking_x - last_pos.x;
  double dy_from_last = tracking_y - last_pos.y;
  double distance =
      sqrt(dx_from_last * dx_from_last + dy_from_last * dy_from_last);

  int captureDir = 0;
  bool isCaptured = false;
  double holdingProgress = 0.0;
  int64_t current_time_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count();

  if (forceCapture) {
    // Force final capture.
    // Increased threshold to 50 pixels to ensure we don't capture the same spot
    // twice.
    if (distance > 50.0) {
      // Be more sensitive to direction prediction during a final forced
      // capture. Even a 10% move towards the next slot should trigger a
      // coordinate change.
      if (abs(dx_from_last) > abs(dy_from_last) * 1.1 &&
          distance > overlapRatioTrigger * 0.1) {
        if (dx_from_last > 0 && allowRight)
          captureDir = 1; // Right
      } else if (abs(dy_from_last) > abs(dx_from_last) * 1.1 &&
                 distance > overlapRatioTrigger * 0.1) {
        if (dy_from_last > 0 && allowDown)
          captureDir = 2; // Down
        else if (dy_from_last < 0 && allowUp)
          captureDir = 3; // Up
      }

      int targetRow = gridY;
      int targetCol = gridX;
      if (captureDir == 1)
        targetCol++;
      else if (captureDir == 2)
        targetRow++;
      else if (captureDir == 3)
        targetRow--;

      int cropX = bgrFrame.cols * 0.08;
      int cropY = bgrFrame.rows * 0.08;
      int cropW = bgrFrame.cols - 2 * cropX;
      int cropH = bgrFrame.rows - 2 * cropY;
      Mat cropped = bgrFrame(Rect(cropX, cropY, cropW, cropH)).clone();

      capturedFrames.push_back({cropped, targetRow, targetCol});
      capturedPositions.push_back(Point2f(tracking_x, tracking_y));
      isCaptured = true;
    }
  } else if (distance >= overlapRatioTrigger * 0.85 &&
             distance < overlapRatioTrigger * 1.5) {
    bool validAlignment = false;

    // Enforce strict straight-line movements, preventing diagonal drift
    if (abs(dx_from_last) > abs(dy_from_last) * 1.5) {
      if (dx_from_last > 0 && allowRight) {
        captureDir = 1;
        validAlignment = true;
      }
    } else if (abs(dy_from_last) > abs(dx_from_last) * 1.5) {
      if (dy_from_last > 0 && allowDown) {
        captureDir = 2;
        validAlignment = true;
      } else if (dy_from_last < 0 && allowUp) {
        captureDir = 3;
        validAlignment = true;
      }
    }

    if (validAlignment) {
      if (hold_start_ms == 0) {
        hold_start_ms = current_time_ms;
      }
      holdingProgress = (double)(current_time_ms - hold_start_ms) / 300.0;
      if (holdingProgress >= 1.0) {
        int targetRow = gridY;
        int targetCol = gridX;
        if (captureDir == 1)
          targetCol++;
        else if (captureDir == 2)
          targetRow++;
        else if (captureDir == 3)
          targetRow--;

        // Crop frame to match the center "Capture Box" UI
        int cropX = bgrFrame.cols * 0.08;
        int cropY = bgrFrame.rows * 0.08;
        int cropW = bgrFrame.cols - 2 * cropX;
        int cropH = bgrFrame.rows - 2 * cropY;
        Mat cropped = bgrFrame(Rect(cropX, cropY, cropW, cropH)).clone();

        capturedFrames.push_back({cropped, targetRow, targetCol});
        capturedPositions.push_back(Point2f(tracking_x, tracking_y));
        isCaptured = true;
        dx_from_last = 0.0;
        dy_from_last = 0.0;
        hold_start_ms = 0;
        holdingProgress = 0.0;
      }
    } else {
      hold_start_ms = 0;
    }
  } else {
    hold_start_ms = 0;
  }

  jdoubleArray result = env->NewDoubleArray(6);
  jdouble values[6] = {isCaptured ? 1.0 : 0.0, dx_from_last,
                       dy_from_last,           overlapRatioTrigger,
                       (double)captureDir,     holdingProgress};
  env->SetDoubleArrayRegion(result, 0, 6, values);
  return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_shelf_1scanner_MainActivity_stitchFramesNative(
    JNIEnv *env, jobject /* this */, jstring _outputPath) {

  const char *path = env->GetStringUTFChars(_outputPath, 0);
  std::string outputPath(path);
  env->ReleaseStringUTFChars(_outputPath, path);

  if (capturedFrames.size() < 2) {
    return env->NewStringUTF(""); // Empty means failed
  }

  // 1. Group captured frames into columns
  std::map<int, std::vector<CapturedFrame>> columnsMap;
  for (const auto &frame : capturedFrames) {
    columnsMap[frame.col].push_back(frame);
  }

  // 2. Stitch each column vertically into a vertical strip
  std::vector<Mat> columnStrips;
  for (auto &pair : columnsMap) {
    auto &frames = pair.second;

    // Sort frames within the column by their row index (TOP to BOTTOM)
    std::sort(frames.begin(), frames.end(),
              [](const CapturedFrame &a, const CapturedFrame &b) {
                return a.row < b.row;
              });

    if (frames.size() == 1) {
      columnStrips.push_back(frames[0].image);
    } else {
      std::vector<Mat> colImages;
      for (const auto &f : frames)
        colImages.push_back(f.image);

      Mat colResult;
      Ptr<Stitcher> colStitcher = Stitcher::create(Stitcher::SCANS);
      colStitcher->setRegistrationResol(0.6); // High detail for shelf patterns
      Stitcher::Status status = colStitcher->stitch(colImages, colResult);

      if (status == Stitcher::OK && !colResult.empty()) {
        columnStrips.push_back(colResult);
      } else {
        // If column fails, pick middle image as fallback or combine vertically?
        // Fallback to simpler concat if stitcher fails on vertical strip
        columnStrips.push_back(frames[frames.size() / 2].image);
      }
    }
  }

  // 3. Stitch all vertical strips together horizontally
  if (columnStrips.empty())
    return env->NewStringUTF("");

  Mat finalPanorama;
  if (columnStrips.size() == 1) {
    finalPanorama = columnStrips[0];
  } else {
    Ptr<Stitcher> rowStitcher = Stitcher::create(Stitcher::SCANS);
    rowStitcher->setRegistrationResol(
        0.8); // Ultra high detail for cross-column registration
    Stitcher::Status status = rowStitcher->stitch(columnStrips, finalPanorama);

    if (status != Stitcher::OK || finalPanorama.empty()) {
      // Fallback to first available segment if final horizontal stitch fails
      finalPanorama = columnStrips[0];
    }
  }

  if (!finalPanorama.empty()) {
    imwrite(outputPath, finalPanorama);
    return env->NewStringUTF(outputPath.c_str());
  }

  return env->NewStringUTF("");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_shelf_1scanner_MainActivity_getCapturedFramesNative(
    JNIEnv *env, jobject /* this */, jstring _outputDir) {

  const char *dirPath = env->GetStringUTFChars(_outputDir, 0);
  std::string outputDir(dirPath);
  env->ReleaseStringUTFChars(_outputDir, dirPath);

  if (capturedFrames.empty())
    return env->NewStringUTF("");

  int64_t timestamp = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::system_clock::now().time_since_epoch())
                          .count();

  std::string result = "";
  for (size_t i = 0; i < capturedFrames.size(); i++) {
    std::string colLetter = getExcelColumnName(capturedFrames[i].col);

    // Naming format: [Coord]_[DisplayIndex]_[Timestamp]_[Dimension].jpg
    // DisplayIndex starts at 1 now.
    std::string fileName =
        "/" + colLetter + std::to_string(capturedFrames[i].row) + "_" +
        std::to_string(i + 1) + "_" + std::to_string(timestamp) + "_" +
        std::to_string(capturedFrames[i].image.cols) + "x" +
        std::to_string(capturedFrames[i].image.rows) + ".jpg";
    std::string fullPath = outputDir + fileName;

    imwrite(fullPath, capturedFrames[i].image);

    result += std::to_string(capturedFrames[i].row) + "," +
              std::to_string(capturedFrames[i].col) + "," + fullPath;

    if (i < capturedFrames.size() - 1) {
      result += ";";
    }
  }

  return env->NewStringUTF(result.c_str());
}
