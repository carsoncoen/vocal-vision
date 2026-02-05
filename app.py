import cv2
import pyttsx3
import threading
import time
from ultralytics import YOLO

# Initialize the Text-to-Speech engine
engine = pyttsx3.init()

# Global flag to check if the engine is currently talking
is_speaking = False

def speak_func(text):
    global is_speaking
    try:
        engine.say(text)
        engine.runAndWait()
    except:
        pass
    finally:
        # When done speaking, set the flag back to False
        is_speaking = False

def main():
    # --- FIX: Declare global variable at the very start of the function ---
    global is_speaking 

    # 1. Load Model
    model = YOLO('yolov8n.pt')

    # 2. Setup Webcam
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("Error: Could not open webcam.")
        return

    # 3. Timer Setup
    last_announcement_time = 0
    announcement_interval = 2.0  # Seconds

    print("Starting... Press 'q' to exit.")

    while True:
        success, frame = cap.read()
        if not success:
            break

        # Run detection
        results = model(frame, stream=True, verbose=False)

        current_objects = set()
        person_count = 0
        
        # Process results
        for r in results:
            annotated_frame = r.plot()
            for box in r.boxes:
                class_id = int(box.cls[0])
                class_name = model.names[class_id]

                if class_name == 'person':
                    person_count += 1
                else:
                    current_objects.add(class_name)

        # Logic for Person vs People
        if person_count == 1:
            current_objects.add('person')
        elif person_count > 1:
            current_objects.add('people')

        # --- TIMER LOGIC ---
        current_time = time.time()
        
        # Check if 2 seconds have passed AND if we are not currently speaking
        if (current_time - last_announcement_time > announcement_interval) and not is_speaking:
            
            if current_objects:
                text_to_say = ", ".join(current_objects)
                print(f"Speaking: {text_to_say}")
                
                # Set flag to True so we don't trigger again immediately
                is_speaking = True
                
                # Start speech thread
                t = threading.Thread(target=speak_func, args=(text_to_say,))
                t.start()
                
                # Reset the timer
                last_announcement_time = current_time

        # Display
        cv2.imshow("YOLOv8 Periodic Speech", annotated_frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()