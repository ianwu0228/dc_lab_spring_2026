#include <Arduino.h>

  const uint8_t STEP_PIN = 2;
  const uint8_t DIR_PIN = 3;
  const uint8_t ENABLE_PIN = 4;

  // Adjust this if motion is too fast or too slow.
  const unsigned long FIXED_STEPS_PER_SECOND = 200;
  const unsigned long STEP_PERIOD_US = 1000000UL / FIXED_STEPS_PER_SECOND;

  // DRV8825 needs STEP high pulse >= about 1.9 us.
  const unsigned int STEP_PULSE_US = 5;

  bool directionForward = true;
  bool driverEnabled = false;
  String inputLine;

  void enableDriver() {
    driverEnabled = true;
    digitalWrite(ENABLE_PIN, LOW); // DRV8825 ENABLE is active low.
    Serial.println("Driver enabled");
  }

  void disableDriver() {
    driverEnabled = false;
    digitalWrite(ENABLE_PIN, HIGH);
    Serial.println("Driver disabled");
  }

  void setDirection(bool forward) {
    directionForward = forward;
    digitalWrite(DIR_PIN, forward ? HIGH : LOW);
    Serial.println(forward ? "Direction: forward" : "Direction: backward");
  }

  void pulseStep() {
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(STEP_PULSE_US);
    digitalWrite(STEP_PIN, LOW);
  }

  void moveSteps(long steps) {
    if (steps == 0) {
      Serial.println("Step count must not be 0");
      return;
    }

    bool originalDirection = directionForward;
    long stepCount = steps;

    if (steps < 0) {
      setDirection(!directionForward);
      stepCount = -steps;
    }

    enableDriver();

    Serial.print("Moving ");
    Serial.print(stepCount);
    Serial.print(" steps at ");
    Serial.print(FIXED_STEPS_PER_SECOND);
    Serial.println(" steps/s");

    for (long i = 0; i < stepCount; i++) {
      pulseStep();
      delayMicroseconds(STEP_PERIOD_US - STEP_PULSE_US);
    }

    if (steps < 0) {
      setDirection(originalDirection);
    }

    Serial.println("Move complete");
  }

  void printHelp() {
    Serial.println();
    Serial.println("DRV8825 step calibration commands:");
    Serial.println("  s 1000    Move 1000 steps");
    Serial.println("  s -1000   Move 1000 steps opposite direction");
    Serial.println("  f         Set direction forward");
    Serial.println("  b         Set direction backward");
    Serial.println("  e         Enable driver");
    Serial.println("  d         Disable driver");
    Serial.println("  h/?       Help");
    Serial.println();
    Serial.println("Recommended calibration:");
    Serial.println("  1. Mark start position");
    Serial.println("  2. Run: s 1000");
    Serial.println("  3. Measure displacement in mm");
    Serial.println("  4. Compute steps_per_mm = 1000 / measured_mm");
    Serial.println();
  }

  void handleCommand(String line) {
    line.trim();
    if (line.length() == 0) {
      return;
    }

    char command = line.charAt(0);
    String arg = "";
    if (line.length() > 1) {
      arg = line.substring(1);
      arg.trim();
    }

    switch (command) {
      case 's':
        moveSteps(arg.toInt());
        break;

      case 'f':
        setDirection(true);
        break;

      case 'b':
        setDirection(false);
        break;

      case 'e':
        enableDriver();
        break;

      case 'd':
        disableDriver();
        break;

      case 'h':
      case '?':
        printHelp();
        break;

      default:
        Serial.println("Unknown command. Type h for help.");
        break;
    }
  }

  void readSerialCommands() {
    while (Serial.available() > 0) {
      char c = Serial.read();

      if (c == '\n' || c == '\r') {
        if (inputLine.length() > 0) {
          handleCommand(inputLine);
          inputLine = "";
        }
      } else {
        inputLine += c;
      }
    }
  }

  void setup() {
    Serial.begin(115200);

    pinMode(STEP_PIN, OUTPUT);
    pinMode(DIR_PIN, OUTPUT);
    pinMode(ENABLE_PIN, OUTPUT);

    digitalWrite(STEP_PIN, LOW);
    setDirection(true);
    disableDriver();

    Serial.println("DRV8825 step/mm calibration sketch");
    Serial.print("Fixed speed: ");
    Serial.print(FIXED_STEPS_PER_SECOND);
    Serial.println(" steps/s");

    printHelp();
  }

  void loop() {
    readSerialCommands();
  }