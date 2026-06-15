#include <Arduino.h>
#include <math.h>

/*
 * Two MCP4725 test using fast software I2C on Arduino Mega PORTA pins.
 *
 * DAC 1:
 *   Pin 22 = PA0 = SDA
 *   Pin 23 = PA1 = SCL
 *   Output sine frequency = 45 Hz
 *
 * DAC 2:
 *   Pin 24 = PA2 = SDA
 *   Pin 25 = PA3 = SCL
 *   Output sine frequency = 75 Hz
 *
 * Wiring:
 *   Arduino GND must connect to both MCP4725 GND pins.
 *   Arduino 5V can power the MCP4725 boards if the boards support 5V.
 *
 * Each I2C bus needs SDA/SCL pull-ups to the MCP4725 logic supply.
 * Many MCP4725 breakout boards already include these pull-ups.
 */

const uint8_t MCP4725_ADDR = 0x60;

const uint8_t DAC1_SDA_MASK = _BV(0);  // Mega pin 22, PA0
const uint8_t DAC1_SCL_MASK = _BV(1);  // Mega pin 23, PA1
const uint8_t DAC2_SDA_MASK = _BV(2);  // Mega pin 24, PA2
const uint8_t DAC2_SCL_MASK = _BV(3);  // Mega pin 25, PA3

const float dac1Freq = 45.0;
const float dac2Freq = 75.0;

const uint16_t targetUpdatesPerSecond = 2700;
const uint16_t dac1SamplesPerCycle = 60;  // 2700 / 45 = 60
const uint16_t dac2SamplesPerCycle = 36;  // 2700 / 75 = 36
const uint16_t dac1SampleRate = dac1Freq * dac1SamplesPerCycle;
const uint16_t dac2SampleRate = dac2Freq * dac2SamplesPerCycle;

const uint16_t dacMid = 2048;
const uint16_t dacAmp = 100;

// Set this to 1 to measure the maximum DAC write speed.
// Set it back to 0 to output the normal 45 Hz / 75 Hz sine waves.
#define SPEED_TEST_MODE 0

uint16_t dac1Table[dac1SamplesPerCycle];
uint16_t dac2Table[dac2SamplesPerCycle];

struct SoftI2CBus {
  uint8_t sdaMask;
  uint8_t sclMask;
};

SoftI2CBus dac1Bus = { DAC1_SDA_MASK, DAC1_SCL_MASK };
SoftI2CBus dac2Bus = { DAC2_SDA_MASK, DAC2_SCL_MASK };

static inline void i2cDelay() {
  delayMicroseconds(1);
}

static inline void lineLow(uint8_t mask) {
  PORTA &= ~mask;
  DDRA |= mask;
}

static inline void lineRelease(uint8_t mask) {
  DDRA &= ~mask;
}

static inline bool lineRead(uint8_t mask) {
  return (PINA & mask) != 0;
}

static inline void busRelease(const SoftI2CBus &bus) {
  lineRelease(bus.sdaMask);
  lineRelease(bus.sclMask);
}

static inline void i2cStart(const SoftI2CBus &bus) {
  lineRelease(bus.sdaMask);
  lineRelease(bus.sclMask);
  i2cDelay();
  lineLow(bus.sdaMask);
  i2cDelay();
  lineLow(bus.sclMask);
}

static inline void i2cStop(const SoftI2CBus &bus) {
  lineLow(bus.sdaMask);
  i2cDelay();
  lineRelease(bus.sclMask);
  i2cDelay();
  lineRelease(bus.sdaMask);
}

static bool i2cWriteByte(const SoftI2CBus &bus, uint8_t data) {
  for (uint8_t bit = 0; bit < 8; bit++) {
    if (data & 0x80) {
      lineRelease(bus.sdaMask);
    } else {
      lineLow(bus.sdaMask);
    }

    i2cDelay();
    lineRelease(bus.sclMask);
    i2cDelay();
    lineLow(bus.sclMask);

    data <<= 1;
  }

  lineRelease(bus.sdaMask);
  i2cDelay();
  lineRelease(bus.sclMask);
  i2cDelay();

  bool ack = !lineRead(bus.sdaMask);

  lineLow(bus.sclMask);
  return ack;
}

static bool dacSetVoltage(const SoftI2CBus &bus, uint16_t value) {
  value &= 0x0FFF;

  i2cStart(bus);

  bool ok = true;
  ok &= i2cWriteByte(bus, (MCP4725_ADDR << 1) | 0x00);

  // MCP4725 fast mode write:
  // Byte 1: C2 C1 PD1 PD0 D11 D10 D9 D8
  // For DAC register only, C2:C1 = 00 and PD1:PD0 = 00.
  ok &= i2cWriteByte(bus, (value >> 8) & 0x0F);
  ok &= i2cWriteByte(bus, value & 0xFF);

  i2cStop(bus);
  return ok;
}

static void fillSineTable(uint16_t *table, uint16_t sampleCount) {
  for (uint16_t i = 0; i < sampleCount; i++) {
    float theta = 2.0 * PI * i / sampleCount;
    table[i] = dacMid + dacAmp * sin(theta);
  }
}

void setup() {
  Serial.begin(115200);

  PORTA &= ~(DAC1_SDA_MASK | DAC1_SCL_MASK | DAC2_SDA_MASK | DAC2_SCL_MASK);
  busRelease(dac1Bus);
  busRelease(dac2Bus);

  fillSineTable(dac1Table, dac1SamplesPerCycle);
  fillSineTable(dac2Table, dac2SamplesPerCycle);

  Serial.println("Two MCP4725 fast software I2C sine test");
  Serial.println("DAC1: SDA=22, SCL=23, sine=45 Hz");
  Serial.println("DAC2: SDA=24, SCL=25, sine=75 Hz");
  Serial.print("Target updates/s per DAC = ");
  Serial.println(targetUpdatesPerSecond);
  Serial.print("DAC1 samples per cycle = ");
  Serial.println(dac1SamplesPerCycle);
  Serial.print("DAC2 samples per cycle = ");
  Serial.println(dac2SamplesPerCycle);
}

void loop() {
#if SPEED_TEST_MODE
  static unsigned long lastStatusMs = 0;
  static uint32_t dac1AckFailCount = 0;
  static uint32_t dac2AckFailCount = 0;
  static uint32_t dac1UpdateCount = 0;
  static uint32_t dac2UpdateCount = 0;
  static uint32_t dac1LastUpdateCount = 0;
  static uint32_t dac2LastUpdateCount = 0;
  static uint16_t value = dacMid - dacAmp;
  static int16_t step = 8;

  if (!dacSetVoltage(dac1Bus, value)) {
    dac1AckFailCount++;
  }
  dac1UpdateCount++;

  if (!dacSetVoltage(dac2Bus, value)) {
    dac2AckFailCount++;
  }
  dac2UpdateCount++;

  value += step;
  if (value >= dacMid + dacAmp || value <= dacMid - dacAmp) {
    step = -step;
  }

  unsigned long nowMs = millis();
  if (nowMs - lastStatusMs >= 1000) {
    lastStatusMs = nowMs;

    uint32_t dac1UpdatesPerSecond = dac1UpdateCount - dac1LastUpdateCount;
    uint32_t dac2UpdatesPerSecond = dac2UpdateCount - dac2LastUpdateCount;
    dac1LastUpdateCount = dac1UpdateCount;
    dac2LastUpdateCount = dac2UpdateCount;

    Serial.print("[SPEED TEST] DAC1 ACK fail = ");
    Serial.print(dac1AckFailCount);
    Serial.print(" | max updates/s = ");
    Serial.print(dac1UpdatesPerSecond);
    Serial.print(" | DAC1-table sine equivalent Hz = ");
    Serial.print((float)dac1UpdatesPerSecond / dac1SamplesPerCycle, 2);

    Serial.print(" || DAC2 ACK fail = ");
    Serial.print(dac2AckFailCount);
    Serial.print(" | max updates/s = ");
    Serial.print(dac2UpdatesPerSecond);
    Serial.print(" | DAC2-table sine equivalent Hz = ");
    Serial.println((float)dac2UpdatesPerSecond / dac2SamplesPerCycle, 2);
  }
#else
  static uint16_t dac1Index = 0;
  static uint16_t dac2Index = 0;

  static unsigned long dac1LastMicros = 0;
  static unsigned long dac2LastMicros = 0;
  static unsigned long lastStatusMs = 0;

  static uint32_t dac1AckFailCount = 0;
  static uint32_t dac2AckFailCount = 0;
  static uint32_t dac1UpdateCount = 0;
  static uint32_t dac2UpdateCount = 0;
  static uint32_t dac1LastUpdateCount = 0;
  static uint32_t dac2LastUpdateCount = 0;

  const unsigned long dac1PeriodUs = 1000000UL / dac1SampleRate;
  const unsigned long dac2PeriodUs = 1000000UL / dac2SampleRate;

  unsigned long now = micros();

  if (now - dac1LastMicros >= dac1PeriodUs) {
    dac1LastMicros += dac1PeriodUs;

    if (!dacSetVoltage(dac1Bus, dac1Table[dac1Index])) {
      dac1AckFailCount++;
    }

    dac1UpdateCount++;
    dac1Index++;
    if (dac1Index >= dac1SamplesPerCycle) {
      dac1Index = 0;
    }
  }

  now = micros();

  if (now - dac2LastMicros >= dac2PeriodUs) {
    dac2LastMicros += dac2PeriodUs;

    if (!dacSetVoltage(dac2Bus, dac2Table[dac2Index])) {
      dac2AckFailCount++;
    }

    dac2UpdateCount++;
    dac2Index++;
    if (dac2Index >= dac2SamplesPerCycle) {
      dac2Index = 0;
    }
  }

  unsigned long nowMs = millis();
  if (nowMs - lastStatusMs >= 1000) {
    lastStatusMs = nowMs;

    uint32_t dac1UpdatesPerSecond = dac1UpdateCount - dac1LastUpdateCount;
    uint32_t dac2UpdatesPerSecond = dac2UpdateCount - dac2LastUpdateCount;
    dac1LastUpdateCount = dac1UpdateCount;
    dac2LastUpdateCount = dac2UpdateCount;

    Serial.print("DAC1 ACK fail = ");
    Serial.print(dac1AckFailCount);
    Serial.print(" | updates/s = ");
    Serial.print(dac1UpdatesPerSecond);
    Serial.print(" | estimated Hz = ");
    Serial.print((float)dac1UpdatesPerSecond / dac1SamplesPerCycle, 2);

    Serial.print(" || DAC2 ACK fail = ");
    Serial.print(dac2AckFailCount);
    Serial.print(" | updates/s = ");
    Serial.print(dac2UpdatesPerSecond);
    Serial.print(" | estimated Hz = ");
    Serial.println((float)dac2UpdatesPerSecond / dac2SamplesPerCycle, 2);
  }
#endif
}
