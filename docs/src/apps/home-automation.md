# Home Automation

All home-automation apps live in the `home-automation` namespace. Pods that need direct L2 access to IoT devices attach a secondary interface to VLAN 1152 (IOT) via Multus.

---

## Applications

| App            | Purpose                                  |
| -------------- | ---------------------------------------- |
| Home Assistant | Central home automation hub              |
| Frigate        | NVR / AI camera monitoring               |
| ESPHome        | ESP8266/ESP32 device firmware management |
| Zigbee2MQTT    | Zigbee coordinator → MQTT bridge         |
| Mosquitto      | MQTT broker                              |
| Matter Server  | Matter/Thread protocol support           |
| Homebridge     | HomeKit bridge for non-native devices    |
| Node-RED       | Visual automation flows                  |

---

## Network Architecture

Pods requiring IoT network access use a Multus `NetworkAttachmentDefinition` (`iot` in `kube-system`) to attach a secondary NIC on VLAN 1152. This allows:

- Frigate to discover and stream RTSP/ONVIF cameras on the IOT subnet
- Home Assistant to communicate directly with devices
- Zigbee2MQTT to reach the Zigbee coordinator USB dongle (passed through to the pod)

The primary pod interface remains on the cluster overlay network (VLAN 1099).

---

## Home Assistant

Central hub connecting all other automation apps. Integrations include Zigbee (via Zigbee2MQTT + MQTT), ESPHome devices, Frigate (via MQTT + API), Matter devices, and Homebridge.

---

## Frigate

AI-based NVR. Runs on the `talos-gpu-01` node for hardware-accelerated object detection via the Intel Arc A380 GPU (VAAPI).

---

## Mosquitto

MQTT broker used by Zigbee2MQTT, Frigate, ESPHome, and Home Assistant as the messaging backbone.

---

## Zigbee2MQTT

Bridges Zigbee devices to MQTT. Requires a USB Zigbee coordinator passed through to the pod.

---

## Node-RED

Visual flow editor for automation logic. Runs as a companion to Home Assistant for complex automations.
