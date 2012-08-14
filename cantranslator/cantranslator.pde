/*
 *
 *  Derived from CanDemo.pde, example code that came with the
 *  chipKIT Network Shield libraries.
 */

#include <stdint.h>
#include "chipKITCAN.h"
#include "chipKITUSBDevice.h"
#include "bitfield.h"
#include "canutil_chipkit.h"
#include "canwrite_chipkit.h"
#include "usbutil.h"
#include "serialutil.h"
#include "cJSON.h"
#include "signals.h"

#define VERSION_CONTROL_COMMAND 0x80
#define RESET_CONTROL_COMMAND 0x81

// USB
#define DATA_ENDPOINT 1

char* VERSION = "2.0-pre";
CAN can1(CAN::CAN1);
CAN can2(CAN::CAN2);

// USB

#define DATA_ENDPOINT 1

USB_HANDLE USB_OUTPUT_HANDLE = 0;
SerialDevice serialDevice = {&Serial1};
CanUsbDevice usbDevice = {USBDevice(usbCallback), DATA_ENDPOINT,
        ENDPOINT_SIZE, &serialDevice, true};

int receivedMessages = 0;
unsigned long lastSignificantChangeTime;
int receivedMessagesAtLastMark = 0;

/* Forward declarations */

void initializeAllCan();
void receiveCan(CanBus*);
void checkIfStalled();
bool receiveWriteRequest(char*);

void setup() {
    Serial.begin(115200);

    initializeSerial(&serialDevice);
    initializeUsb(&usbDevice);
    armForRead(&usbDevice, usbDevice.receiveBuffer);
    initializeAllCan();
    lastSignificantChangeTime = millis();
}

void loop() {
    for(int i = 0; i < getCanBusCount(); i++) {
        receiveCan(&getCanBuses()[i]);
    }
    USB_OUTPUT_HANDLE = readFromHost(
            &usbDevice, USB_OUTPUT_HANDLE, &receiveWriteRequest);
    readFromSerial(&serialDevice, &receiveWriteRequest);
    checkIfStalled();
}

int main(void) {
	init();
	setup();

	for (;;)
		loop();

	return 0;
}

void initializeAllCan() {
    for(int i = 0; i < getCanBusCount(); i++) {
        initializeCan(&(getCanBuses()[i]));
    }
}

void mark() {
    lastSignificantChangeTime = millis();
    receivedMessagesAtLastMark = receivedMessages;
}

void checkIfStalled() {
    // a workaround to stop CAN from crashing indefinitely
    // See these tickets in Redmine:
    // https://fiesta.eecs.umich.edu/issues/298
    // https://fiesta.eecs.umich.edu/issues/244
    if(receivedMessagesAtLastMark + 10 < receivedMessages) {
        mark();
    }

    if(receivedMessages > 0 && receivedMessagesAtLastMark > 0
            && millis() > lastSignificantChangeTime + 500) {
        initializeAllCan();
        delay(1000);
        mark();
    }
}

bool receiveWriteRequest(char* message) {
    cJSON *root = cJSON_Parse(message);
    if(root != NULL) {
        cJSON* nameObject = cJSON_GetObjectItem(root, "name");
        if(nameObject == NULL) {
            Serial.println("Write request is malformed, missing name");
            return true;
        }
        char* name = nameObject->valuestring;
        CanSignal* signal = lookupSignal(name, getSignals(),
                getSignalCount(), true);
        if(signal != NULL) {
            cJSON* value = cJSON_GetObjectItem(root, "value");
            CanCommand* command = lookupCommand(name, getCommands(),
                    getCommandCount());
            if(command != NULL) {
                command->handler(name, value, getSignals(),
                        getSignalCount());
            } else {
                sendCanSignal(signal, value, getSignals(),
                        getSignalCount());
            }
        } else {
            Serial.print("Writing not allowed for signal with name ");
            Serial.println(name);
        }
        cJSON_Delete(root);
        return true;
    }
    return false;
}

/*
 * Check to see if a packet has been received. If so, read the packet and print
 * the packet payload to the serial monitor.
 */
void receiveCan(CanBus* bus) {
    CAN::RxMessageBuffer* message;

    if(bus->messageReceived == false) {
        // The flag is updated by the CAN ISR.
        return;
    }
    ++receivedMessages;

    message = bus->bus->getRxMessage(CAN::CHANNEL1);
    decodeCanMessage(message->msgSID.SID, message->data);

    /* Call the CAN::updateChannel() function to let the CAN module know that
     * the message processing is done. Enable the event so that the CAN module
     * generates an interrupt when the event occurs.*/
    bus->bus->updateChannel(CAN::CHANNEL1);
    bus->bus->enableChannelEvent(CAN::CHANNEL1, CAN::RX_CHANNEL_NOT_EMPTY,
            true);

    bus->messageReceived = false;
}

/* Called by the Interrupt Service Routine whenever an event we registered for
 * occurs - this is where we wake up and decide to process a message. */
void handleCan1Interrupt() {
    if((can1.getModuleEvent() & CAN::RX_EVENT) != 0) {
        if(can1.getPendingEventCode() == CAN::CHANNEL1_EVENT) {
            // Clear the event so we give up control of the CPU
            can1.enableChannelEvent(CAN::CHANNEL1,
                    CAN::RX_CHANNEL_NOT_EMPTY, false);
            getCanBuses()[0].messageReceived = true;
        }
    }
}

void handleCan2Interrupt() {
    if((can2.getModuleEvent() & CAN::RX_EVENT) != 0) {
        if(can2.getPendingEventCode() == CAN::CHANNEL1_EVENT) {
            // Clear the event so we give up control of the CPU
            can2.enableChannelEvent(CAN::CHANNEL1,
                    CAN::RX_CHANNEL_NOT_EMPTY, false);
            getCanBuses()[1].messageReceived = true;
        }
    }
}

static boolean customUSBCallback(USB_EVENT event, void* pdata, word size) {
    switch(SetupPkt.bRequest) {
    case VERSION_CONTROL_COMMAND:
        char combinedVersion[strlen(VERSION) + strlen(getMessageSet()) + 2];

        sprintf(combinedVersion, "%s (%s)", VERSION, getMessageSet());
        Serial.print("Version: ");
        Serial.println(combinedVersion);

        usbDevice.device.EP0SendRAMPtr((uint8_t*)combinedVersion,
                strlen(combinedVersion), USB_EP0_INCLUDE_ZERO);
        return true;
    case RESET_CONTROL_COMMAND:
        Serial.print("Resetting...");
        initializeAllCan();
        return true;
    default:
        return false;
    }
}

static boolean usbCallback(USB_EVENT event, void *pdata, word size) {
    // initial connection up to configure will be handled by the default
    // callback routine.
    usbDevice.device.DefaultCBEventHandler(event, pdata, size);

    switch(event) {
    case EVENT_CONFIGURED:
        Serial.println("Event: Configured");
        usbDevice.configured = true;
        mark();
        usbDevice.device.EnableEndpoint(DATA_ENDPOINT,
                USB_IN_ENABLED|USB_OUT_ENABLED|USB_HANDSHAKE_ENABLED|
                USB_DISALLOW_SETUP);
        armForRead(&usbDevice, usbDevice.receiveBuffer);
        break;

    case EVENT_EP0_REQUEST:
        customUSBCallback(event, pdata, size);
        break;

    default:
        break;
    }
}
