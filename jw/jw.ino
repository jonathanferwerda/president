
// The Start of the JawnWatch (JW)
#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <time.h>



TFT_eSPI tft;
#include <UrlEncode.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <Arduino_JSON.h>
#include <ESP32Time.h>
#include <WiFiAP.h>

#include "FS.h"
#include "FFat.h"
ESP32Time rtc;

// Flag used to indicate whether to use light sleep, currently unavailable
static bool lightSleep = true;
// Flag used for acceleration interrupt status
static bool sportsIrq = false;
// Flag used to indicate whether recording is enabled
static bool recordFlag = false;
// Flag used for PMU interrupt trigger status
static bool pmuIrq = false;
static bool webserver_enabled;// = true;
static bool wifi_ap_enabled = false;
static bool wifi_enabled = false;
char standby_en = 1;
#define DEFAULT_SCREEN_TIMEOUT                  20*1000
String jw_room = "watch";
void settingSensor();
void settingPMU();
uint16_t t_x = 0, t_y = 0;
String authorization;
String authorization_json;
WebServer server(3000);
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
String ssid = "jawn";
String base_ssid = ssid;
String password = "92ae2dd1414dff025e16775f1d";
String base_password = password;
String ap_ssid = "3";
String base_ap_ssid = ap_ssid;
String ap_password = "battlestargalactica";
String base_ap_password = ap_password;
int room = 1;
int room_count = 1;
int room_max = 6;
int b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle = 0;
String returner;
uint32_t lastMillis;
uint32_t buttonMillis = 0;
String before_me = "";
bool buttoned_before = false;
char bufsec[64];
char bufdate[64];
char buftime[64];
char *bufgwIP = new char[40]();
char *bufIP = new char[40]();
char *bufapIP = new char[40]();
char *bufapgwIP = new char[40]();
IPAddress apIP;
String homebase;
String homebaseIP;
String homebaseIPArray[10];
String wifi_update;
JSONVar wigi;
String computer_name;
static RTC_DATA_ATTR int brightnessLevel = 50;
int vibrateLevel = 50;
int volumeLevel = 50;
void lowPowerEnergyHandler();
String chat_room;
bool loraChatBroadcaster = false;
bool loraChatReceiver = false;
bool stepCounter = true;
uint32_t steps;
JSONVar stepped;
#include <driver/i2s.h>
#include <driver/gpio.h>

#include <AudioFileSourcePROGMEM.h>
#include <AudioFileSourceID3.h>
#include <AudioGeneratorMP3.h>
#include <AudioGeneratorWAV.h>
#include <AudioOutputI2S.h>
#include <AudioFileSourceFATFS.h>

AudioGeneratorMP3       *mp3;
AudioFileSourcePROGMEM  *file;
AudioOutputI2S          *out;
AudioFileSourceID3      *id3;
AudioGeneratorWAV       *wav;
AudioFileSourceFATFS    *file_fs;


#define FORMAT_FFAT true

SX1262 radio = newModule();
volatile bool operationDone = false;
bool transmitFlag = false;
void setFlag(void) {
  // we sent or received a packet, set the flag
  operationDone = true;
}

lv_obj_t * btn1;
lv_obj_t * btn2;
lv_obj_t * btn3;
lv_obj_t * btn4;
lv_obj_t * btn5;
lv_obj_t * btn6;

void setup() {
  Serial.begin(921600);
  Serial.println("setup started");
  Serial.println("setup started time");

  watch.begin();
  setCpuFrequencyMhz(240);
    Serial.println("setup started watch");
  time_writer("now");

  settingSensor();
  Serial.println("setup started sensor");

 //if (FORMAT_FFAT) FFat.format();
  if (!FFat.begin()) {
    Serial.println("FFat Mount Failed");
    return;
  }
  else {
    Serial.println("Mounted FFat partition");
    Serial.printf("Total space: %10u\n", FFat.totalBytes());
    Serial.printf("Free space: %10u\n", FFat.freeBytes());    
  }

  // Serial.print(F("[SX1262] Initializing ... "));
  // set output power to 10 dBm (accepted range is -17 - 22 dBm)
  if (radio.setOutputPower(22) == RADIOLIB_ERR_INVALID_OUTPUT_POWER) {
      // Serial.println(F("Selected output power is invalid for this module!"));
      while (true);
  }
  // set over current protection limit to 80 mA (accepted range is 45 - 240 mA)
  // NOTE: set value to 0 to disable overcurrent protection
  if (radio.setCurrentLimit(80) == RADIOLIB_ERR_INVALID_CURRENT_LIMIT) {
      // Serial.println(F("Selected current limit is invalid for this module!"));
      while (true);
  }    
  int state = radio.begin(433);
  if (state == RADIOLIB_ERR_NONE) {
    // Serial.println(F("success!"));
    radio.setDio1Action(setFlag);

    radio.startReceive();
  } else {
    // Serial.print(F("failed, code "));
    // Serial.println(state);
    while (true);
  }

  


  beginLvglHelper();
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_hex(0x000000), LV_PART_MAIN);


  // Set the interrupt handler of the PMU
  watch.attachPMU(setPMUFlag);
  watch.setSysPowerDownVoltage(2600);
  setCpuFrequencyMhz(80);
  button_writer();

  settingPMU();
  server.on("/", []() {
    server.send(200, "text/plain", "<html><h1>JAWN WATCH!</h1><h4>Do you even know?</h4></html>");
  });
  server.on("/notification", []() {
    notification_display(server.arg("title"), server.arg("notification"));;
    server.send(200, "text/plain", "this works as well");
  });
  server.on("/wifi_update", []() {
    String req = "https://" + homebaseIP + "/teletype/wifi_update?timestamp=" + rtc.getLocalEpoch();
    // Serial.println(req);
    wifi_update = https_request(req);
    // Serial.println(wifi_update);
    JSONVar info = JSON.parse(wifi_update);
    if (ssid != (const char *)info["ssid"] || password != (const char *)info["password"]) {
      ssid = (const char *)info["ssid"];
      password = (const char *)info["password"];
      WiFi.disconnect();
      delay(400);
      wifi_server();
    }
    if (ap_ssid != (const char *)info["ap_ssid"] && ap_password != (const char *)info["ap_password"]) {
      ap_ssid = (const char *)info["ap_ssid"];
      ap_password = (const char *)info["ap_password"];
      // Serial.println(ssid);
      // Serial.println(password);
      // Serial.println(ap_ssid);
      // Serial.println(ap_password);
      accesspoint_stop();
      delay(400);
      accesspoint_start();
    }

    JSONVar pa;
    pa["ap_ssid"] = ap_ssid;
    pa["ap_password"] = ap_password;
    String public_announcement = JSON.stringify(pa);
  //  radio.startTransmit(public_announcement);
  //  server.send(200, "text/plain", "done");
  //  delay(1000);
    radio.startReceive();
    server.send(200, "text/plain", "sent wifi info");
  });
  server.on("/send_telephone", []() {
    Serial.println("send telephone");
    String temp_authorization = server.arg("authorization");
    Serial.println(temp_authorization);
      Serial.println("in the temp auth");
      JSONVar m;
      m["msg"] = server.arg("msg");
      m["app"] = server.arg("app");
      String jsm = JSON.stringify(m);
      Serial.println("Sending msg: " + jsm);
      radio.startTransmit(jsm);
      delay(1000);
      radio.startReceive();
      server.send(200, "text/plain", "transmission sent");
      buttonMillis = millis();
      lastMillis = millis();
      pmuIrq = true;
  });
  
  server.on("/chat_received", []() {
    if (buttoned_before) {
      Serial.println(server.arg("s"));
      String s = server.arg("s");
      String uuid = server.arg("uuid");
      chat_grabber(s,uuid);
      server.send(200, "text/plain", "done");
    }
    else {
      server.send(200, "text/plain", "unknown");
    }
  });
server.on("/device_query", []() {
    JSONVar g;
    String chip_id = chip_id_maker();
    g["chip_id"] = chip_id;
    g["name"] = "LilyGo T-Watch S3";
    g["uptime"] = millis();
    g["purpose"] = "watch";
    String gs = JSON.stringify(g);
    server.send(200, "text/plain", gs);

  });  
  server.on("/wigi", []() {
    String rauth = server.arg("authorization");
    if (rauth == authorization) {

      JSONVar wigi_s;
      wigi_s["buttons"] = wigi;
      wigi_s["measures"]["steps"] = stepped;
      wigi_s["authorization"] = authorization;
      long timestamp = rtc.getLocalEpoch() - rtc.offset;  

      wigi_s["timestamp"] = timestamp;
      String wigis = JSON.stringify(wigi_s);
      server.send(200,"text/plain", wigis);
      String resetter = "[]";
      wigi = JSON.parse(resetter);
      stepped = JSON.parse(resetter);
      watch.resetPedometer();    
      step_writer();
    }
    else {
      server.send(200,"text/plain", "{}");
    }
  });
  server.on("/now_me", []() {
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    authorization = server.arg("authorization");
    long timestamp = server.arg("timestamp").toInt();
    rtc.setTime(timestamp);
    long offset = server.arg("offset").toInt();
    rtc.offset = offset;
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    
    room_count = server.arg("room_count").toInt();
  //  room_max = server.arg("room_max").toInt();

    pmuIrq = true;
    buttoned_before = false;
    // Serial.println("now me in room " + room);
    b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle = 0;
     Serial.println(authorization);
    //call_the_president();
    remote_room();
    buttonMillis = millis();
    lastMillis = millis();
    
     Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
  });
//  wifi_server();
  watch.enableSystemVoltageMeasure();
  readFile(FFat, "/bootreport.txt");
  if (returner == "success") {
    configRestore();
    Serial.println("After the restore");
  }
  lv_task_handler();

}


void chat_grabber(String s, String uuid) {
  Serial.println(s);
  if (authorization) {
    String request = "https://" + homebaseIP + "/watch/chat_grabber?s=" + s + "&uuid=" + uuid;
    Serial.println(request);
    String response = https_request(request);
    Serial.println(response);
    JSONVar mail = JSON.parse(response);
    buttonMillis = millis();
    String manager_file = mail["manager_file"];
    String body = mail["body"]; 
    long timestamp = mail["timestamp"];
    loraChatBroadcast(manager_file, body, timestamp);    
  }
}

void loraChatBroadcast(String computer_name, String body, long timestamp) {
  if (loraChatBroadcaster) {
    
    JSONVar msg;
    msg["u"] = computer_name;
    msg["m"] = body;
    
    String returns = JSON.stringify(msg);
    Serial.println(returns);
    radio.startTransmit(returns);
    Serial.println("transmitted");
   // delay(2000);
  //   radio.startReceive();
    Serial.println("back to listening");
  }
}

void step_writer() {
  if (sportsIrq && stepCounter == true) {
    uint16_t status =   watch.readBMA();
    Serial.println("activity " + status);
    steps = watch.getPedometerCounter();
    JSONVar last_step;
    long timestamp = rtc.getLocalEpoch() - rtc.offset;

    int l = stepped.length();
    last_step["timestamp"] = timestamp;
    last_step["steps"] = steps;
    stepped[l] = last_step;
    sportsIrq = false;
    String stepper = JSON.stringify(stepped);
    Serial.println(stepper);

  } 
}


void loop() {
  char count = 0;;
//  watch.attachPMU(setPMUFlag);

  if (jw_room == "watch") {
    time_writer("loop");
    step_writer();   
  }
  else if (jw_room == "net") {
    ip_writer();
  }
  else if (jw_room == "message") {
    if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count < 350) {
      lowPowerEnergyHandler();
      count = 0;
      jw_room = "watch";
    }
    else {
      count++;
    }
    delay(60);
  }
  watch.setTextFont(2);
  int volts = watch.getBatteryPercent();
  if (volts < 20) {
    watch.setTextColor(TFT_RED, TFT_BLACK);
  }
  else if (volts < 40) {
    watch.setTextColor(TFT_YELLOW, TFT_BLACK);
  }
  else {
    watch.setTextColor(TFT_GREEN, TFT_BLACK);
  }
  watch.drawNumber(watch.getBattVoltage(), 214, 5 );
  watch.drawNumber(watch.getBatteryPercent(), 15, 5);
  watch.drawString("%", 29, 5);
  if (computer_name != "") {
    watch.drawString(computer_name, 120, 5);
  }
  else {
   watch.drawString(homebaseIP, 120, 5);
  }
  touch_watch();
  if (buttonMillis == 0 && sportsIrq == 0) {
    setSportsFlag();
    settingPMU();
    pmuIrq = false;
    buttonMillis = millis();
  }


  if (!pmuIrq) {
    lv_task_handler();
    if (webserver_enabled == true) {
      server.handleClient();
    }
    delay(5);
  }
  else {
    lowPowerEnergyHandler();
  }
  if (loraChatReceiver) {
    readRadio();
  }
  if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT) {
    lowPowerEnergyHandler();
  }

}

void readRadio() {
  if (operationDone) {
    operationDone = false;
    String str;      
    int state = radio.readData(str);
    if (state == RADIOLIB_ERR_NONE) {
      // packet was successfully received
      // Serial.println(F("[SX1262] Received packet!"));
      
      // print data of the packet
      // Serial.print(F("[SX1262] Data:\t\t"));
      // Serial.println(str);
      
      // print RSSI (Received Signal Strength Indicator)
      // Serial.print(F("[SX1262] RSSI:\t\t"));
      // Serial.print(radio.getRSSI());
      // Serial.println(F(" dBm"));
      
      // print SNR (Signal-to-Noise Ratio)
      // Serial.print(F("[SX1262] SNR:\t\t"));
      // Serial.print(radio.getSNR());
      // Serial.println(F(" dB"));
      radio.startReceive();

      JSONVar js = JSON.parse(str);
      String string = JSON.stringify(js);
      Serial.println(str);
      String ssid_check = (const char *)js["ap_ssid"];
      String msg_check = (const char *)js["msg"];
      String chat_check = (const char *)js["m"];
      if (chat_check != "") {
        String username = js["u"];
        String message = js["m"];
        Serial.println(str);
        if (authorization != "") {
          String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(message) + "&username=" + urlEncode(username);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
        }
      }
      else if (ssid_check != "") {
        Serial.println("Got an ssid " + ssid_check);
        ssid = (const char *)js["ap_ssid"];
        password = (const char *)js["ap_password"];
      
        webserver_enabled = true;
        wifi_server();        
        delay(1000);
        // Serial.print("Transmitting...");
  
        JSONVar returner;
        returner["time"] = rtc.getLocalEpoch();
        String returns = JSON.stringify(returner);
     //   radio.startTransmit(returns);
     //   Serial.println(returns);
     //   delay(1000);
      }
      else if (msg_check != "") {
        buttonMillis = millis();
        lastMillis = millis();
        pmuIrq = true;
        String app = (const char *)js["app"];
        
        Serial.println("Got a message: " + msg_check);
        JSONVar result = JSON.parse(https_request(
          "https://" + homebaseIP +
          "/watch/telephone_msg?timestamp=" + rtc.getLocalEpoch() +
          "&msg=" + msg_check + "&app=" + app
        ));
        String rs = JSON.stringify(result);
        Serial.println(rs);
      }
    }
  }
}
void wifi_server() {
  if (ssid == "" && password == "") {
    wifi_enabled = false;
    return;
  }
  if (wifi_enabled == true) {
    if (WiFi.status() != WL_CONNECTED) {
      WiFi.begin(ssid, password);
    }
    int tryDelay = 420;
    int numberOfTries = 12;
    while (true) {
  
      switch (WiFi.status()) {
        case WL_NO_SSID_AVAIL:
          // Serial.println("[WiFi] SSID not found");
          break;
        case WL_CONNECT_FAILED:
          // Serial.print("[WiFi] Failed - WiFi not connected! Reason: ");
          return;
          break;
        case WL_CONNECTION_LOST:
          // Serial.println("[WiFi] Connection was lost");
          break;
        case WL_SCAN_COMPLETED:
          // Serial.println("[WiFi] Scan is completed");
          break;
        case WL_DISCONNECTED:
          // Serial.println("[WiFi] WiFi is disconnected");
          break;
        case WL_CONNECTED:
          // Serial.println("[WiFi] WiFi is connected!");
          // Serial.print("[WiFi] IP address: ");
          // Serial.println(WiFi.localIP());
          server.begin();
          webserver_enabled = true;
          wifi_enabled = true;
          return;
          break;
        default:
          // Serial.print("[WiFi] WiFi Status: ");
          // Serial.println(WiFi.status());
          break;
      }
      delay(tryDelay);
      if (numberOfTries <= 0) {
        Serial.print("Wifi failed to connect");
        Serial.print(ssid + " " + password);
        WiFi.disconnect();
        wifi_enabled = false;
        return;
      }
      else {
        numberOfTries--;
      }
    }
    while (WiFi.status() != WL_CONNECTED) {
      delay(100);
      // Serial.print(".");
    }
  }
}


void notification_display(String title, String notification) {
  jw_room = "message";


  static const char *btns[] = {""};

  int t_length = title.length() + 1;
  int n_length = notification.length() + 1;
  char t[t_length];
  char n[n_length];

  title.toCharArray(t, t_length);
  notification.toCharArray(n, n_length);

  lv_obj_t * mb = lv_msgbox_create(lv_scr_act(), t, n, btns, true);


  //  lv_obj_center(mb);
  lv_obj_set_y(mb, 35);

  lv_task_handler();
  wakeup();
}

void wakeup() {
  // Serial.println("Wakeup");
  watch.configreFeatureInterrupt(
    SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
    SensorBMA423::INT_ACTIVITY |    // Activity interruption
    SensorBMA423::INT_TILT |        // Tilt interrupt
    // SensorBMA423::INT_WAKEUP |      // DoubleTap interrupt
    SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
    true);
  watch.incrementalBrightness(brightnessLevel);
  //display_exit();
  buttonMillis = millis();
  lastMillis = millis();
  pmuIrq = false;
  watch.setWaveform(0, vibrateLevel);  // play effect
  // play the effect!
  watch.run();

  
}

void display_exit( void ) {
  lv_obj_clean ( lv_scr_act() ); // Clean objects from current screen.
  lv_obj_invalidate( lv_scr_act() ); // Invalidate objects for redraw.
  button_writer();
//  time_writer("now");
}

void time_writer(char * situation) {
  if (situation == "now") {
    tft.fillScreen(TFT_BLACK);
  }
  if (millis() - lastMillis > 1000 || situation == "now") {

    lastMillis = millis();

    struct tm timeinfo;
    // Get the time C library structure
    watch.getDateTime(&timeinfo);
    size_t written_date = strftime(bufdate, 64, "%a %b %d %Y", &timeinfo);
    size_t written_time = strftime(buftime, 64, "%H:%M", &timeinfo);
    size_t written_sec = strftime(bufsec, 64, "%S", &timeinfo);
    watch.setTextFont(2);
    watch.setTextColor(TFT_YELLOW, TFT_BLACK);
    if (written_date != 0) {

      watch.drawString(bufdate, 120, 20);
    }
    if (written_time != 0) {
      watch.setTextFont(8);
      watch.drawString(buftime, 120, 70);
    }
    if (written_sec != 0) {
      watch.setTextFont(4);
      watch.drawString(bufsec, 120, 130);
    }
    if (stepCounter == true) {
      watch.setCursor(10,140);
      watch.print(steps);
    }
  }
}

void ip_writer() {
  watch.setTextFont(2);
  IPAddress ip = WiFi.localIP();
  sprintf(bufIP, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  watch.setTextColor(TFT_BLACK, TFT_WHITE);
  IPAddress gw_ip = WiFi.gatewayIP();
  sprintf(bufgwIP, "%d.%d.%d.%d", gw_ip[0], gw_ip[1], gw_ip[2], gw_ip[3]);
  watch.drawString(bufIP, 50, 130);
  watch.drawString(bufgwIP, 190, 130);
  if (wifi_ap_enabled) {
    apIP = WiFi.softAPIP();
    sprintf(bufapIP, "%d.%d.%d.%d", apIP[0], apIP[1], apIP[2], apIP[3] );
    watch.drawString(bufapIP, 50, 150);
    watch.drawString(bufapgwIP, 190, 150);
  }  
}

void button_writer() {
  btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, touch_button1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 65, 190 );
  lv_obj_set_size(btn1, 50, 50 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "Rom");
  lv_obj_center(l1);

  btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, touch_button2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 10, 190 );
  lv_obj_set_size(btn2, 50, 50 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xffca38), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "Clk");
  lv_obj_center(l2);

  btn3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn3, touch_button3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn3, 120, 190 );
  lv_obj_set_size(btn3, 50, 50 );
  lv_obj_set_style_bg_color(btn3, lv_color_hex(0xfa3ced), LV_PART_MAIN);

  lv_obj_t *l3;
  lv_color_t t3;
  t3 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
  l3 = lv_label_create(btn3);
  lv_label_set_text(l3, "Set");
  lv_obj_center(l3);

  btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, touch_button4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 175, 190 );
  lv_obj_set_size(btn6, 50, 50 );
  lv_obj_set_style_bg_color(btn6, lv_color_hex(0x1aacfd), LV_PART_MAIN);

  lv_obj_t *l6;
  lv_color_t t6;
  t6 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn6, t6, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "Net");
  lv_obj_center(l6);

  lv_task_handler();
}


void https_download(fs::FS &fs, String url, String filename) {
  url = url_maker(url);
  Serial.println("In the https download");
  Serial.println(url);
  connexion -> setInsecure();
  if (connexion) {
    {
      if (https.begin(*connexion, url)) {

        int httpCode = https.GET();
        Serial.println("Did a get");
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            //  writeFile(FFat, filename.c_str(), "");

            int len = https.getSize();
            Serial.println(len);
            uint8_t buff[1048] = { 0 };

            WiFiClient * stream = https.getStreamPtr();
            while (https.connected() &&  (len > 0 || len == -1)) {
              // read up to 128 byte
              size_t size = stream->available();
              Serial.println(size);
              if (size) {
                Serial.println("Got a size");
                int c = stream->readBytes(buff, ((size > sizeof(buff)) ? sizeof(buff) : size));

                // write it to Serial
                //  Serial.write(buff, c);
                appendFile(FFat, filename.c_str(), (char *) buff);
                if (len > 0) {
                  len -= c;
                }
              }
            }
          }
        }
      }
      https.end();

    }
  }
}

String chip_id_maker() {
  uint32_t chipId = 0;
  for(int i=0; i<17; i=i+8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

String url_maker(String url) {
  String chip_id = chip_id_maker();
  long timestamp = rtc.getLocalEpoch() - rtc.offset;  
  url = url + "&edt=watch&chip_id=" + chip_id + "&authorization=" + authorization + "&timestamp=" + timestamp;
  return url;
}

String https_request(String url) {
  url = url_maker(url);
  Serial.println(url);
  WiFiClientSecure *connexion = new WiFiClientSecure;
  String https_returner = "failure";
  connexion -> setInsecure();
  if (connexion) {
    // Serial.println ("there is a connection");
    {
      HTTPClient https;
      if (https.begin(*connexion, url)) {
         Serial.println("est connection");
        int httpCode = https.GET();
      
        if (httpCode > 0) {
           Serial.printf("HTTPS GET code: %d\n", httpCode);

          if (httpCode == HTTP_CODE_OK) {
            String payload = https.getString();
             Serial.print(payload);
             Serial.println(payload);
            return payload;

          }
        }
        else {
          // Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          writeFile(FFat, "/bootreport.txt", "failure");

          return "failure";
        }
        https.end();
      }
    }
  }
  return https_returner;
}

void call_the_president() {
  // Serial.println("dans presidente");
  // Serial.println(before_me);
  // Serial.println("copy");
  JSONVar result;

  if (!buttoned_before) {
    String req = "https://" + homebaseIP + "/watch?room=" + room;
     Serial.println(req);
    String watchRequest = https_request(req);
     Serial.println(watchRequest);
    if (watchRequest != "failure") {
      Serial.println("President doesnt see it as a failure");
      before_me = watchRequest;
      buttoned_before = true;
      result = JSON.parse(before_me);
      
      // Serial.println(before_me);
      int32_t year = result["__specs"]["time"]["year"];
      int32_t month = result["__specs"]["time"]["month"];
      int32_t day =  result["__specs"]["time"]["day"];;
      int32_t hour =  result["__specs"]["time"]["hour"];
      int32_t minute = result["__specs"]["time"]["min"];
      int32_t second = result["__specs"]["time"]["sec"];
    
      watch.setDateTime(year, month, day, hour, minute, second);
      // Reading time synchronization from RTC to system time
      watch.hwClockRead();
      buttonMillis = millis();
      lastMillis = millis();
  
    }
    else {
      writeFile(FFat, "/bootreport.txt", "failure");

    }
    Serial.println("after watch request");

  }
  else {
    Serial.println("Not buttoned before");
  }

}

void presidents_buttons() {
  JSONVar result;
  Serial.println("in the buttons");
  lv_obj_t * led1  = lv_led_create(lv_scr_act());
  lv_obj_set_pos(led1, 10, 160 );
  lv_led_set_color(led1, lv_palette_main(LV_PALETTE_RED));
  lv_led_off(led1);
  lv_obj_t * led2 = lv_label_create(lv_scr_act());
  lv_obj_set_pos(led2, 45, 160);
  lv_obj_set_style_text_color(led2, lv_palette_main(LV_PALETTE_GREEN), LV_PART_MAIN);

  if (!buttoned_before) {
    watch.drawString("Ne pas Presidente", 80, 80);
    lv_led_off(led1);
    return;
  }
  else {
    result = JSON.parse(before_me);
  }
  if (wigi.length() > 0) {
    lv_led_on(led1);
    int wl = wigi.length();
    char wil[4];
    itoa( wl, wil, 10 );
    lv_label_set_text(led2, wil);
  } 
  else {
    lv_label_set_text(led2, "0");
  }
  Serial.println("after before me parsing");
  if (room > room_count) { room = 1; }  
  int sb = ((room - 1) * 6) + 1;

  // Serial.println(room);
  // Serial.println(sb);
  lv_obj_t * b1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b1, mb1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b1, 10, 10 );
  lv_obj_set_size(b1, 60, 60 );
  lv_color_t c1;
  lv_color_t t1;
  int tog1 = result["b" + String(sb)]["toggle"]; 

  if (tog1 == 1) {
    t1 = lv_color_make(0,0,0);
    c1 = lv_color_make(255,255,0);
  }
  else {
    c1 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t1 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b1, t1, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b1, c1, LV_PART_MAIN);
  lv_obj_t *l1;
  l1 = lv_label_create(b1);
  lv_label_set_text(l1, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l1);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b1_toggle);
  lv_obj_t * b2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b2, mb2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b2, 90, 10 );
  lv_obj_set_size(b2, 60, 60 );
  lv_color_t c2;
  lv_color_t t2;
  int tog2 = result["b" + String(sb)]["toggle"]; 
  
  if (tog2 == 1) {
    t2 = lv_color_make(0,0,0);
    c2 = lv_color_make(255,255,0);
  }
  else {
    c2 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t2 = lv_color_make(255,255,255);
  }  
  lv_obj_set_style_bg_color(b2, c2, LV_PART_MAIN);
  lv_obj_set_style_text_color(b2, t2, LV_PART_MAIN);  
  lv_obj_t *l2;
  l2 = lv_label_create(b2);
  lv_label_set_text(l2, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l2);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b2_toggle);
  lv_obj_t * b3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b3, mb3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b3, 170, 10 );
  lv_obj_set_size(b3, 60, 60 );
  lv_color_t c3;
  lv_color_t t3;
  int tog3 = result["b" + String(sb)]["toggle"]; 

  if (tog3 == 1) {
    t3 = lv_color_make(0,0,0);
    c3 = lv_color_make(255,255,0);
  }
  else {
    c3 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t3 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b3, t3, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b3, c3, LV_PART_MAIN);
  lv_obj_t *l3;
  l3 = lv_label_create(b3);
  lv_label_set_text(l3, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l3);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b3_toggle);
  lv_obj_t * b4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b4, mb4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b4, 10, 90 );
  lv_obj_set_size(b4, 60, 60 );
  lv_color_t c4;
  lv_color_t t4;
  int tog4 = result["b" + String(sb)]["toggle"]; 

  if (tog4 == 1) {
    t4 = lv_color_make(0,0,0);
    c4 = lv_color_make(255,255,0);
  }
  else {
    c4 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t4 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b4, t4, LV_PART_MAIN);  
  lv_obj_set_style_bg_color(b4, c4, LV_PART_MAIN);
  lv_obj_t *l4;
  l4 = lv_label_create(b4);
  lv_label_set_text(l4, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l4);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b4_toggle);
  lv_obj_t * b5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b5, mb5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b5, 90, 90 );
  lv_obj_set_size(b5, 60, 60 );
  lv_color_t c5;
  lv_color_t t5;
  int tog5 = result["b" + String(sb)]["toggle"]; 

  if (tog5 == 1) {
    t5 = lv_color_make(0,0,0);
    c5 = lv_color_make(255,255,0);
  }
  else {
    t5 = lv_color_make(255,255,255);
    c5 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
  }
  lv_obj_set_style_text_color(b5, t5, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b5, c5, LV_PART_MAIN);
  lv_obj_t *l5;
  l5 = lv_label_create(b5);
  lv_label_set_text(l5, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l5);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b5_toggle);
  // Serial.println("b" + String(sb));
  lv_obj_t * b6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b6, mb6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b6, 170, 90 );
  lv_obj_set_size(b6, 60, 60 );
  lv_color_t c6;
  lv_color_t t6;
  // Serial.println(result["b" + String(sb)]["toggle"]);
  int tog6 = result["b" + String(sb)]["toggle"]; 
  if (tog6 == 1) {
    c6 = lv_color_make(255,255,0);
    t6 = lv_color_make(0,0,0);
  }
  else {
    c6 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t6 = lv_color_make(255,255,255);
  }  
  lv_obj_set_style_bg_color(b6, c6, LV_PART_MAIN);
  lv_obj_set_style_text_color(b6, t6, LV_PART_MAIN);    
  
  lv_obj_t *l6;
  l6 = lv_label_create(b6);
  lv_label_set_text(l6, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l6);
  buttonMillis = millis();
}

static void touch_button1(lv_event_t *e) {
  if (jw_room == "room") {
    if (room == room_count) {
      room = 1;

    }
    else {
      room++;
    }
  }
  remote_room();
}

void remote_room() {
  jw_room = "room";
  display_exit();
  watch.fillScreen(TFT_BLACK);
  call_the_president();
  presidents_buttons();
  button_writer();
}

unsigned long getTime() {
  time_t now;
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) {
    //Serial.println("Failed to obtain time");
    return (0);
  }
  time(&now);
  return now;
}

void when_i_get_in(JSONVar wigi_item) {
  
  int l = wigi.length();
  if (l < 0) {
    l = 0;
  }
  long timestamp = rtc.getLocalEpoch() - rtc.offset;  
  wigi_item["timestamp"] = timestamp;
  int room = wigi_item["room"];
  int button = wigi_item["button"];
  
  JSONVar bm = JSON.parse(before_me);
  
  int rooming = (((room - 1 ) * room_max) + button);
  String roomings = String(rooming);
  JSONVar buttonski = bm["b" + roomings];
  String bs = JSON.stringify(buttonski);
  
  String movement = (const char *)buttonski["movement"];
  int toggle = buttonski["toggle"];
  
  if (movement == "start") {
    if (toggle == 1) {
      bm["b" + roomings]["toggle"] = 0;
    }
    else {
      bm["b" + roomings]["toggle"] = 1;
    }
    before_me = JSON.stringify(bm);
    presidents_buttons();
  }


  wigi[l] = wigi_item;
}

void mb1(lv_event_t *e) {
  if (b1_toggle == 0) {
    b1_toggle = 1;
  } else {
    b1_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=1&toggle=" + b1_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 1;
    updater["toggle"] = b1_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  
  b1_toggle = result["toggle"];
  
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b1_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 1)] = result;
  before_me = JSON.stringify(bm);

}
void mb2(lv_event_t *e) {
  if (b2_toggle == 0) {
    b2_toggle = 1;
  } else {
    b2_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=2&toggle=" + b2_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 2;
    updater["toggle"] = b2_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b2_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target(e);
  if (b2_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);  
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);   
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);                 
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 2)] = result;
  before_me = JSON.stringify(bm);
}
void mb3(lv_event_t *e) {
  if (b3_toggle == 0) {
    b3_toggle = 1;
  } else {
    b3_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=3&toggle=" + b3_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 3;
    updater["toggle"] = b3_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b3_toggle = result["toggle"];
  // Serial.println(b3_toggle);
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b3_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0,0,0);
   
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 3)] = result;
  before_me = JSON.stringify(bm);
}
void mb4(lv_event_t *e) {
  if (b4_toggle = 0) {
    b4_toggle = 1;
  } else {
    b4_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=4&toggle=" + b4_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 4;
    updater["toggle"] = b4_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b4_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target(e);
  if (b4_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 4)] = result;
  before_me = JSON.stringify(bm);

}
void mb5(lv_event_t *e) {
  if (b5_toggle == 0) {
    b5_toggle = 1;
  } else {
    b5_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=5&toggle=" + b5_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 5;
    updater["toggle"] = b5_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b5_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 5)] = result;
  before_me = JSON.stringify(bm);
}
void mb6(lv_event_t *e) {
  if (b6_toggle == 0) {
    b6_toggle = 1;
  } else {
    b6_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=6&toggle=" + b6_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 6;
    updater["toggle"] = b6_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b6_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b6_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 6)] = result;
  before_me = JSON.stringify(bm);
}


static void touch_button2(lv_event_t *e) {
  clock_writer();
}

void clock_writer() {
  
  display_exit();

  delay(5);
  if (jw_room != "watch") {
    time_writer("now");
  }
  jw_room = "watch";
  
  delay(5);
  lastMillis = lastMillis - 1000;
  lv_task_handler();
}


static void touch_button3(lv_event_t *e) {
  setting_room();
}
void setting_room() {
  display_exit();
  jw_room = "configure";
  lv_obj_t *slider = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider, brightnessLevel, LV_ANIM_ON);
  lv_obj_set_width(slider, 150);
  lv_obj_set_pos(slider, 10, 20);
  lv_obj_add_event_cb(slider, brightness_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t *slider1 = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider1, vibrateLevel, LV_ANIM_ON);

  lv_obj_set_width(slider1, 150);
  lv_obj_set_pos(slider1, 10, 45);
  lv_obj_add_event_cb(slider1, vibrate_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t *slider2 = lv_slider_create(lv_scr_act());
  lv_obj_set_width(slider2, 150);
  lv_obj_set_pos(slider2, 10, 70);
  lv_obj_add_event_cb(slider2, volume_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
  lv_slider_set_value(slider2, volumeLevel, LV_ANIM_ON);
  lv_slider_set_range(slider2, 0, 100);

  lv_obj_t * pd_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(pd_button, step_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(pd_button, 10, 100 );
  lv_obj_set_size(pd_button, 40, 40 );
  if (stepCounter == true) {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi1;
  lv_color_t twi1;
  twi1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(pd_button, twi1, LV_PART_MAIN);
  lwi1 = lv_label_create(pd_button);
  lv_label_set_text(lwi1, "PD");
  lv_obj_center(lwi1);


  lv_obj_t * btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, ap_lora_send, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 190, 10 );
  lv_obj_set_size(btn1, 40, 40 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_task_handler();
  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "LAP");
  lv_obj_center(l1);

  lv_obj_t * btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, wifi_lora_send, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 190, 50 );
  lv_obj_set_size(btn2, 40, 40 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "LWI");
  lv_obj_center(l2);

  
  lv_color_t t5;
  t5 = lv_color_make(0,0,0);
  lv_obj_t * btn5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn5, loraBroadcastToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn5, 190, 100 );
  lv_obj_set_size(btn5, 40, 40 );
  if (loraChatBroadcaster == false) {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }  
  lv_obj_t *l5;
  lv_obj_set_style_text_color(btn5, t5, LV_PART_MAIN);
  l5 = lv_label_create(btn5);
  lv_label_set_text(l5, "LB");
  lv_obj_center(l5);  


  lv_obj_t * btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, loraReceiveToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 140, 100 );
  lv_obj_set_size(btn6, 40, 40 );
  if (loraChatReceiver == true) {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }  
  lv_obj_t *l6;
  lv_obj_set_style_text_color(btn6, t5, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "LR");
  lv_obj_center(l6); 

  lv_color_t t50;
  t50 = lv_color_make(0,0,0);
  lv_obj_t * btn50 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn50, configSaveButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn50, 190, 140 );
  lv_obj_set_size(btn50, 40, 40 );
  lv_obj_t *l50;
  lv_obj_set_style_text_color(btn50, t50, LV_PART_MAIN);
  l50 = lv_label_create(btn50);
  lv_label_set_text(l50, "cS");
  lv_obj_center(l50);  


  lv_obj_t * btn60 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn60, configRestoreButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn60, 140, 140 );
  lv_obj_set_size(btn60, 40, 40 );
  lv_obj_t *l60;
  lv_obj_set_style_bg_color(btn60, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_set_style_text_color(btn60, t50, LV_PART_MAIN);
  l60 = lv_label_create(btn60);
  lv_label_set_text(l60, "cR");
  lv_obj_center(l60);

  lv_obj_t * btn601 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn601, configDeleteButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn601, 90, 140 );
  lv_obj_set_size(btn601, 40, 40 );
  lv_obj_t *l601;
  lv_obj_set_style_bg_color(btn601, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_set_style_text_color(btn601, t50, LV_PART_MAIN);
  l601 = lv_label_create(btn601);
  lv_label_set_text(l601, "cD");
  lv_obj_center(l601);

  lv_obj_t * btn6012 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6012, lightSleep_toggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6012, 10, 140 );
  lv_obj_set_size(btn6012, 40, 40 );
  lv_obj_t *l6012;
  if (lightSleep == true) {
    lv_obj_set_style_bg_color(btn6012, lv_color_hex(0x5afcdd), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn6012, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_set_style_text_color(btn6012, t50, LV_PART_MAIN);
  l6012 = lv_label_create(btn6012);
  lv_label_set_text(l6012, "LS");
  lv_obj_center(l6012);   

  lv_task_handler();
}

static void step_control(lv_event_t *e) {
  lv_obj_t * pd_button = lv_event_get_target(e);

  if (stepCounter == true) {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    stepCounter = false;
    watch.disablePedometer();
    watch.disablePedometerIRQ();

  }
  else {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    stepCounter = true;
    watch.enablePedometer();
    watch.enablePedometerIRQ();

  }
}

static void lightSleep_toggle(lv_event_t *e) {
  lv_obj_t * sleep_button = lv_event_get_target(e);  

  if (lightSleep == true) {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    lightSleep = false;
  }
  else {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    lightSleep = true;
  }
}

static void configSaveButton(lv_event_t *e) {
  configSave();
}

static void configRestoreButton(lv_event_t *e) {
  configRestore();
  setting_room();
  
}

static void configDeleteButton(lv_event_t *e) {
  configDelete();
}


static void loraBroadcastToggle(lv_event_t *e) {
  lv_obj_t * lora_button = lv_event_get_target(e);  
  if (loraChatBroadcaster == false) {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0x53ff24), LV_PART_MAIN);
    loraChatBroadcaster = true;

  }
  else {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    loraChatBroadcaster = false;

  }
}

static void loraReceiveToggle(lv_event_t *e) {
  lv_obj_t * lora_button = lv_event_get_target(e);  
  if (loraChatReceiver == false) {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0x53ff24), LV_PART_MAIN);
    loraChatReceiver = true;
  }
  else {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    loraChatReceiver = false;
  }
}

static void ap_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ap_ssid;
  pa["ap_password"] = ap_password;
  String public_announcement = JSON.stringify(pa);
  radio.startTransmit(public_announcement);
  //Serial.print(public_announcement);
}


static void wifi_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ssid;
  pa["ap_password"] = password;
  String public_announcement = JSON.stringify(pa);
  radio.startTransmit(public_announcement);
  //Serial.print(public_announcement);
}


static void wifi_ap_control(lv_event_t *e) {
  lv_obj_t * wifi_ap_button = lv_event_get_target(e);
  if (wifi_ap_enabled == true) {
    wifi_ap_enabled = false;  
    accesspoint_stop();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    
  }
  else {
    wifi_ap_enabled = true;
    accesspoint_start();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

void accesspoint_start() {
  if (wifi_ap_enabled == true) {
    IPAddress gw_ip(192, 168, 3, 1);
    IPAddress ip(192, 168, 3, 1);
    IPAddress subnet(255, 255, 255, 0);
    if (wifi_update != "") {
      JSONVar wifi = JSON.parse(wifi_update);
      ap_ssid = (const char *)wifi["ap_ssid"];
      ap_password = (const char *)wifi["ap_password"];
    }
    if (WiFi.softAP(ap_ssid, ap_password)) {
      WiFi.softAPConfig(ip, gw_ip, subnet); //, IPAddress dhcp_lease_start = (uint32_t)0, IPAddress dns = (uint32_t)0);
      server.begin();
      webserver_enabled = true;
      wifi_ap_enabled = true;
      apIP = WiFi.softAPIP();
    }
  }
}

void accesspoint_stop() {
  WiFi.softAPdisconnect();
  server.stop();
  wifi_ap_enabled = false;
  if (wifi_enabled == false) {
    webserver_enabled = false;
  }
}



static void wifi_control(lv_event_t *e) {
  lv_obj_t * wifi_button = lv_event_get_target(e);
  if (wifi_enabled == true) {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    WiFi.disconnect();
    if (wifi_ap_enabled == false) {
      webserver_enabled = false;
      server.stop();
    }
    wifi_enabled = false;
  }
  else {
    wifi_enabled = true;
    wifi_server();
    if (WiFi.status() == WL_CONNECTED) {
      server.begin();
      server.handleClient();
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
      webserver_enabled = true;
    }
    else {
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
      server.stop();
      wifi_enabled = false;
      if (wifi_ap_enabled == false) {
        webserver_enabled = false;
      }      
    }
  }
}

static void brightness_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  brightnessLevel = level;
  watch.setBrightness(brightnessLevel);

}

static void vibrate_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  vibrateLevel = level;
  watch.setWaveform(0, vibrateLevel);  // play effect
  // play the effect!
  watch.run();
}

static void volume_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  volumeLevel = level;
}


void touch_watch() {
  if (watch.getTouched()) {
    buttonMillis = millis();
    //    lv_point_t point;
    //    lv_indev_t *indev = lv_indev_get_next(NULL);
    //    lv_indev_get_point(indev, &point);
    //    Serial.print(point.x); Serial.print(" "); Serial.println(point.y);

  }
}

void lowPowerEnergyHandler()
{
  Serial.println("Enter light sleep mode!");
 
  buttonMillis = 0;
  brightnessLevel = watch.getBrightness();
  watch.decrementBrightness(0);

  watch.clearPMU();

  watch.configreFeatureInterrupt(
    SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
    SensorBMA423::INT_ACTIVITY |    // Activity interruption
    SensorBMA423::INT_TILT |        // Tilt interrupt
    SensorBMA423::INT_WAKEUP |      // DoubleTap interrupt
    SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
    false);

  sportsIrq = false;
  pmuIrq = false;

  //TODO: Low power consumption not debugged
  if (lightSleep) {
  //  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
    // esp_sleep_enable_ext1_wakeup(1ULL << BOARD_BMA423_INT1, ESP_EXT1_WAKEUP_ANY_HIGH);
    // esp_sleep_enable_ext1_wakeup(1ULL << BOARD_PMU_INT, ESP_EXT1_WAKEUP_ALL_LOW);

//    gpio_wakeup_enable ((gpio_num_t)BOARD_PMU_INT, GPIO_INTR_LOW_LEVEL);
   

    gpio_wakeup_enable ((gpio_num_t)BOARD_BMA423_INT1, GPIO_INTR_HIGH_LEVEL);
    configSave();
    
    esp_sleep_enable_gpio_wakeup();
    esp_light_sleep_start();
    
    Serial.println("right after sleep");
    wifi_server();

  } else {
    configSave();
    setCpuFrequencyMhz(80);
    //my_print("=========esp_light_sleep_start=========\n");
    char count = 0;;

    while (!pmuIrq && !sportsIrq) {// && !watch.getTouched()) {
      if (jw_room == "message") {
        if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count > 58) {
          lowPowerEnergyHandler();
          count = 0;
        }

        else {
          count++;
        }
      }
      if (webserver_enabled == true) {
        server.handleClient();
      }
      readRadio();
      delay(500);
      // gpio_wakeup_enable ((gpio_num_t)BOARD_TOUCH_INT, GPIO_INTR_LOW_LEVEL);
      // esp_sleep_enable_timer_wakeup(3 * 1000);
      // esp_light_sleep_start();
    }
    //my_print("=========esp_light_sleep_end=========\n");

  }
  Serial.println("just before frequency");
  setCpuFrequencyMhz(240);
  step_writer();
  // Clear Interrupts in Loop
  // watch.readBMA();
  // watch.clearPMU();

  watch.configreFeatureInterrupt(
  //  SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
    SensorBMA423::INT_ACTIVITY,     // Activity interruption
 ///   SensorBMA423::INT_TILT |        // Tilt interrupt
 //   SensorBMA423::INT_WAKEUP,       // DoubleTap interrupt
   // SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
  true);
  if (brightnessLevel <= 1) {
    brightnessLevel = 2;
  }
  watch.incrementalBrightness(brightnessLevel);
  
}

void settingSensor()
{
  //Default 4G ,200HZ
  watch.configAccelerometer();

  watch.enableAccelerometer();

  watch.enablePedometer();

  watch.configInterrupt();

  watch.enableFeature(
    SensorBMA423::FEATURE_STEP_CNTR |
    SensorBMA423::FEATURE_ANY_MOTION |
    SensorBMA423::FEATURE_NO_MOTION |
    SensorBMA423::FEATURE_ACTIVITY |
    SensorBMA423::FEATURE_TILT |
    SensorBMA423::FEATURE_WAKEUP,
    true);

  watch.enablePedometerIRQ();
  watch.enableTiltIRQ();
  watch.enableWakeupIRQ();
  watch.enableAnyNoMotionIRQ();
  watch.enableActivityIRQ();

  watch.attachBMA(setSportsFlag);
}

void setSportsFlag()
{
  sportsIrq = true;
}

void setPMUFlag()
{
  pmuIrq = true;
}

void settingPMU()
{
  watch.clearPMU();

  watch.disableIRQ(XPOWERS_AXP2101_ALL_IRQ);
  // Enable the required interrupt function
  watch.enableIRQ(
    // XPOWERS_AXP2101_BAT_INSERT_IRQ    | XPOWERS_AXP2101_BAT_REMOVE_IRQ      |   //BATTERY
    XPOWERS_AXP2101_VBUS_INSERT_IRQ   | XPOWERS_AXP2101_VBUS_REMOVE_IRQ     |   //VBUS
    XPOWERS_AXP2101_PKEY_SHORT_IRQ    | XPOWERS_AXP2101_PKEY_LONG_IRQ       |  //POWER KEY
    XPOWERS_AXP2101_BAT_CHG_DONE_IRQ  | XPOWERS_AXP2101_BAT_CHG_START_IRQ       //CHARGE
    // XPOWERS_AXP2101_PKEY_NEGATIVE_IRQ | XPOWERS_AXP2101_PKEY_POSITIVE_IRQ   |   //POWER KEY
  );
  watch.attachPMU(setPMUFlag);
}


static void touch_button4(lv_event_t *e) {
  net_room();

}

void net_room() {
  jw_room = "net";
  
  display_exit();
  ip_writer();
    lv_obj_t * wifi_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wifi_button, wifi_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wifi_button, 10, 20 );
  lv_obj_set_size(wifi_button, 40, 40 );
  if (wifi_enabled == true) {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi1;
  lv_color_t twi1;
  twi1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(wifi_button, twi1, LV_PART_MAIN);
  lwi1 = lv_label_create(wifi_button);
  lv_label_set_text(lwi1, "WI");
  lv_obj_center(lwi1);

  lv_obj_t * wifi_ap_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wifi_ap_button, wifi_ap_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wifi_ap_button, 60, 20 );
  lv_obj_set_size(wifi_ap_button, 40, 40 );
  if (wifi_ap_enabled == true) {
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi2;
  lv_color_t twi2;
  twi2 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(wifi_ap_button, twi2, LV_PART_MAIN);
  lwi2 = lv_label_create(wifi_ap_button);
  lv_label_set_text(lwi2, "AP");
  lv_obj_center(lwi2);

}

void configSave() {
  JSONVar conf;
  writeFile(FFat, "/bootreport.txt", "success");
  if (lightSleep == true) {
      conf["lightsleep"] = "on";
  }
  else {
    lightSleep == false;
  }
  if (wifi_ap_enabled == true) {
    conf["wifi_ap_enabled"] = "on";
  }
  else {
    conf["wifi_ap_enabled"] = "off";
  }
  if (wifi_enabled == true) {
    conf["wifi_enabled"] = "on";
  }
  else {
    conf["wifi_enabled"] = "off";
  }
  if (loraChatBroadcaster == true) {
    conf["loraChatBroadcaster"] = "on";
  }
  else {
    conf["loraChatBroadcaster"] = "off";
  }
  if (loraChatReceiver == true) {
    conf["loraChatReceiver"] = "on";
  }
  else {
    conf["loraChatReceiver"] = "off";
  }
  if (buttoned_before == true) {
    conf["buttoned_before"] = "on";
  }
  else {
    conf["buttoned_before"] = "off";
  }
  if (stepCounter == true) {
    conf["step_counter"] = "on";
  }
  else {
    conf["step_counter"] = "off";
  }
  conf["before_me"] = before_me;
  conf["jw_room"] = jw_room;
  String wigi_wah = JSON.stringify(wigi);
  conf["wigi"] = wigi_wah;  conf["authorization"] = authorization;
  conf["ssid"] = ssid;
  conf["password"] = password;
  conf["ap_ssid"] = ap_ssid;
  conf["ap_password"] = ap_password;
  String aj = JSON.stringify(authorization_json);
  conf["aj"] = aj;
  conf["before_me"] = before_me;
  conf["homebase"] = homebase;
  conf["homebaseIP"] = homebaseIP;
  conf["computer_name"] = computer_name;
  conf["brightness"] = brightnessLevel;
  conf["vibrate"] = vibrateLevel;
  conf["volume"] = volumeLevel;
  conf["room_count"] = room_count;
  returner = JSON.stringify(conf);
  writeFile(FFat, "/config.json", returner.c_str());
}

void configDelete() {
  FFat.format();

  writeFile(FFat, "/bootreport.txt", "deleting");
  //deleteFile(FFat, "/config.json");
    before_me = "";
  jw_room = "watch";
  homebase = "";
  homebaseIP = "";
  computer_name = "";
  authorization = "";
  ssid = "";
  brightnessLevel = 5;
  password = "";
  ap_ssid = "3";
  room_count = 6;
  ap_password = "battlestargalactica";
  buttoned_before = false;
  wifi_ap_enabled = false;
  wifi_enabled = false;
  loraChatBroadcaster = false;
  loraChatReceiver = false;
  lightSleep = true;
  stepCounter = true;
  wigi = JSON.parse("[]");
}
void configRestore() {
  returner = "";
  Serial.println(returner);
  writeFile(FFat, "/bootreport.txt", "saving");

  readFile(FFat, "/config.json");
  Serial.println(returner);
  Serial.println("ok");
  if (returner != "failure") {
    JSONVar conf = JSON.parse(returner);
    before_me = (const char *)conf["before_me"];
   
    homebase = (const char *)conf["homebase"];
    homebaseIP = (const char *)conf["homebaseIP"];
    computer_name = (const char *)conf["computer_name"];
    authorization = (const char *)conf["authorization"];
    String wigi_wah = conf["wigi"];
    wigi = JSON.parse(wigi_wah);    brightnessLevel = conf["brightness"];
    watch.setBrightness(brightnessLevel);
    
    vibrateLevel = conf["vibrate"];
    volumeLevel = conf["volume"];
    room_count = conf["room_count"];
    if (conf["password"] && conf["ssid"]) {
      password = (const char *)conf["password"];
      ssid = (const char *)conf["ssid"];
    }
    else {
      ssid = base_ssid;
      password = base_password;
    }
    ap_ssid =(const char *)conf["ap_ssid"];
    ap_password = (const char *)conf["ap_password"];
   
    String bb = (const char *)conf["buttoned_before"];
    if (bb == "on") {
      buttoned_before = true;
    }
    else {
      buttoned_before = false;
    }
    String wpae = (const char *)conf["wifi_ap_enabled"];
    if (wpae == "on") {
      wifi_ap_enabled = true;
    }
    else {
      wifi_ap_enabled = false;
    }
  
    accesspoint_start();
    String we = (const char *)conf["wifi_enabled"];
    if (we == "on") {
      wifi_enabled = true;
    }
    else {
      wifi_enabled = false;
    }
    wifi_server();
    String lcb = (const char *)conf["loraChatBroadcaster"];
    if (lcb == "on") {
      loraChatBroadcaster = true;
    }
    else {
      loraChatBroadcaster = false;
    }
    String lcr = (const char *)conf["loraChatReceiver"];
    if (lcr == "on") {
      loraChatReceiver = true;
    }
    else {
      loraChatReceiver = false;
    }
    String ls = (const char *)conf["lightsleep"];
    if (ls == "on") {
      lightSleep = true;
    }
    else {
      lightSleep = false;
    }

    String pd = (const char *)conf["step_counter"];
    if (pd == "on") {
      stepCounter = true;
    }
    else {
      stepCounter = false;
    }
//    call_the_president();
    jw_room = (const char *)conf["jw_room"];
    Serial.print(jw_room);
    Serial.println(" is the room");
    if (jw_room == "room") {
      remote_room();
    }
    else if (jw_room == "watch") {
      clock_writer();
    }
    else if (jw_room == "configure") {
      setting_room();  
    }
    else if (jw_room == "net") {
      net_room();
    }
  }
}


void writeFile(fs::FS &fs, const char * path, const char *  message){
    Serial.printf("Writing file: %s\r\n", path);
    File file = fs.open(path, FILE_WRITE);
    if(!file){
        Serial.println("- failed to open file for writing");
        return;
    }
    if(file.print(message)){
        Serial.println("- file written");
    } else {
        Serial.println("- write failed");
    }
    file.close();
}

String readFile(fs::FS &fs, const char * path) {
  // Serial.printf("Reading file: %s\r\n", path);

  File file = fs.open(path);
  if (!file || file.isDirectory()) {
    // Serial.println("- failed to open file for reading");
    return "failure";
  }
  
  // Serial.println("- read from file:");
  while (file.available()) {
    char fString = (char)file.read();
    returner += fString;
    
  }
  file.close();
  Serial.println(returner);
  return returner;
}

void appendFile(fs::FS &fs, const char * path, const char * message) {
  // Serial.printf("Appending to file: %s\r\n", path);

  File file = fs.open(path, FILE_APPEND);
  if (!file) {
    // Serial.println("- failed to open file for appending");
    return;
  }
  if (file.print(message)) {
    // Serial.println("- message appended");
  } else {
    // Serial.println("- append failed");
  }

  file.close();
}

void createDir(fs::FS &fs, const char * path){
    Serial.printf("Creating Dir: %s\n", path);
    if(fs.mkdir(path)){
        Serial.println("Dir created");
    } else {
        Serial.println("mkdir failed");
    }
}

void deleteFile(fs::FS &fs, const char * path) {
  // Serial.printf("Deleting file: %s\r\n", path);
  if (fs.remove(path)) {
    // Serial.println("- file deleted");
  } else {
    // Serial.println("- delete failed");
  }
}
