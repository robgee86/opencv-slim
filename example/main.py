import cv2
import time
import sys

print("Initializing libcamera pipeline...")

gstreamer_pipeline = (
    "libcamerasrc camera-name=/base/soc@0/cci@5c1b000/i2c-bus@0/sensor@10 ! "
    "video/x-raw, width=1280, height=720 ! "
    "videoconvert ! "
    "videoscale ! "
    "appsink drop=true max-buffers=1"
)
cap = cv2.VideoCapture(gstreamer_pipeline, cv2.CAP_GSTREAMER)

if not cap.isOpened():
    print("Error: Could not open camera.")
    sys.exit(1)

prev_time = time.time()
fps = 0.0
smoothing_factor = 0.1

print("Libcamera pipeline is running. Press 'Ctrl+C' in the terminal to exit.")

try:
    while True:
        ret, frame = cap.read()
        if not ret:
            print("Error: Failed to grab frame.")
            break

        current_time = time.time()
        time_diff = current_time - prev_time
        if time_diff > 0:
            instantaneous_fps = 1.0 / time_diff
            fps = (smoothing_factor * instantaneous_fps) + ((1.0 - smoothing_factor) * fps)

        prev_time = current_time

        sys.stdout.write(f"\rCurrent FPS: {fps:.1f}   ")
        sys.stdout.flush()

except KeyboardInterrupt:
    print("\n\nInterrupted by user. Shutting down...")

finally:
    cap.release()
    print("Done.")
