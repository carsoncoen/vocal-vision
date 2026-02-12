import asyncio
import websockets
import cv2
import numpy as np
import base64
import json
import sys
from ultralytics import YOLO

# Load the YOLOv8 model
model = YOLO("yolo26n.pt") 

# Define the objects you want to detect (must match COCO class names exactly)
TARGET_CLASSES = {"person", "bottle", "dining table", "tv", "keyboard", "laptop"}

async def handle_connection(websocket):
    print("Client connected!")
    try:
        async for message in websocket:
            # ... (Decoding code remains the same) ...
            try:
                data = base64.b64decode(message)
                np_arr = np.frombuffer(data, np.uint8)
                frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
            except:
                continue

            if frame is not None:
                # ... (Inference) ...
                results = model(frame, verbose=False)
                result = results[0]

                detections = []
                
                if result.boxes:
                    for box in result.boxes:
                        # 1. Get Class Name
                        class_id = int(box.cls[0])
                        class_name = model.names[class_id]

                        # 2. FILTER: Only proceed if it's in our target list
                        if class_name in TARGET_CLASSES:
                            coords = box.xyxyn[0].tolist()
                            conf = float(box.conf[0])
                            
                            if conf > 0.4:  # Confidence threshold
                                detections.append({
                                    "class": class_name,
                                    "conf": conf,
                                    "box": coords 
                                })
                # ... (Send JSON back) ...
                await websocket.send(json.dumps(detections))
                
                # Debug print
                if detections:
                    print(f"Detected: {[d['class'] for d in detections]}")
                else:
                    print(".", end="", flush=True)

    except websockets.exceptions.ConnectionClosed:
        print("\nClient disconnected")
    finally:
        cv2.destroyAllWindows()

async def main():
    # Set ping_interval to None to prevent timeouts during processing
    async with websockets.serve(handle_connection, "0.0.0.0", 8765, ping_interval=None):
        print("Server started on ws://0.0.0.0:8765")
        print("Press 'q' in the popup window to stop.")
        
        # Keep the event loop running
        try:
            await asyncio.Future()
        except asyncio.CancelledError:
            pass

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass