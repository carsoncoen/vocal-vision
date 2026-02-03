const video = document.getElementById("video");
const statusText = document.getElementById("status");
const tapNotice = document.getElementById("tapNotice");

let model = null;
let speechEnabled = false;
let lastSpoken = "";
let lastSpokenTime = 0;

// ===============================
// TAP TO ENABLE SPEECH (REQUIRED)
// ===============================
document.body.addEventListener("click", () => {
  if (!speechEnabled) {
    speechEnabled = true;
    tapNotice.textContent = "Speech enabled.";
    speak("Speech enabled. Scanning environment.");
  }
});

// ===============================
// TEXT TO SPEECH
// ===============================
function speak(text) {
  if (!speechEnabled) return;

  const now = Date.now();

  // prevent repeating same message too often
  if (text === lastSpoken && now - lastSpokenTime < 4000) return;

  lastSpoken = text;
  lastSpokenTime = now;

  const utterance = new SpeechSynthesisUtterance(text);
  utterance.rate = 0.9;

  speechSynthesis.cancel();
  speechSynthesis.speak(utterance);
}

// ===============================
// CAMERA SETUP
// ===============================
async function setupCamera() {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: "environment" },
    audio: false
  });

  video.srcObject = stream;

  return new Promise(resolve => {
    video.onloadedmetadata = () => resolve(video);
  });
}

// ===============================
// LOAD OBJECT DETECTION MODEL
// ===============================
async function loadModel() {
  statusText.textContent = "Loading object detection model...";
  model = await cocoSsd.load();
  statusText.textContent = "Model loaded. Point camera around.";
}

// ===============================
// FILTER RELEVANT OBJECTS
// ===============================
function isRelevantObject(name) {
  const relevantObjects = [
    "person",
    "chair",
    "table",
    "couch",
    "backpack",
    "bottle",
    "laptop"
  ];
  return relevantObjects.includes(name);
}

// ===============================
// DETERMINE LEFT / AHEAD / RIGHT
// ===============================
function getDirection(bbox) {
  const [x, , width] = bbox;
  const objectCenter = x + width / 2;
  const screenCenter = video.videoWidth / 2;

  if (objectCenter < screenCenter * 0.8) return "to your left";
  if (objectCenter > screenCenter * 1.2) return "to your right";
  return "ahead";
}

// ===============================
// MAIN DETECTION LOOP
// ===============================
async function detectObjects() {
  if (!model) return;

  const predictions = await model.detect(video);

  const detection = predictions
    .filter(p => p.score > 0.4)
    .find(p => isRelevantObject(p.class));

  if (detection) {
    const direction = getDirection(detection.bbox);
    const message = `${detection.class} ${direction}`;

    statusText.textContent = message;
    speak(message);
  }

  setTimeout(detectObjects, 2000);
}

// ===============================
// START APPLICATION
// ===============================
async function startApp() {
  try {
    await setupCamera();
    await loadModel();
    detectObjects();
  } catch (error) {
    console.error(error);
    statusText.textContent = "Camera access failed.";
    speak("Camera access failed.");
  }
}

startApp();