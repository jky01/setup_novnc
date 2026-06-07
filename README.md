# Ubuntu Wayland RDP to noVNC 橋接服務安裝與設定指南

本指南詳細記錄了如何在 Ubuntu Wayland 環境下，透過 GNOME 內建的 RDP 服務、Xvfb 虛擬顯示器、xfreerdp 用戶端、x11vnc、autocutsel（剪貼簿同步）與 websockify，建立一個支援動態解析度調整與剪貼簿同步的網頁版 noVNC 連線環境。

---

## 1. 架構說明

由於 Wayland 的安全架構限制，傳統的 VNC 伺服器（如 x11vnc）難以直接擷取 Wayland 桌面的畫面。本方案採用以下橋接模式：
1. **GNOME Remote Desktop (RDP)**：負責安全地提供原生 Wayland 桌面的 RDP 串流服務。
2. **Xvfb (X Virtual Framebuffer)**：在背景建立一個虛擬的 X11 顯示環境 (`:99`)。
3. **FreeRDP (`xfreerdp`)**：連線至本機的 GNOME RDP 服務，並將畫面渲染至 Xvfb 虛擬顯示器上，開啟 `/dynamic-resolution` 功能。
4. **x11vnc**：對 Xvfb 虛擬顯示器進行螢幕擷取並提供 VNC 服務。
5. **autocutsel**：雙向同步 X11 剪貼簿與 VNC 剪貼簿。
6. **websockify**：將 VNC 的 TCP 連線轉譯為 WebSocket，以便瀏覽器內建的 noVNC 直接連線。

---

## 2. 安裝套件

執行以下指令安裝所需的套件：

```bash
sudo apt update
sudo apt install -y xvfb x11vnc websockify novnc freerdp3-x11 autocutsel x11-xserver-utils
```
*(註：若系統未提供 `freerdp3-x11`，可安裝 `freerdp2-x11`)*

---

## 3. 設定步驟

### 步驟 3.1：啟用並設定 GNOME RDP 服務
1. 開啟系統內建的 RDP 服務，並設定帳號與密碼（在此設定為使用者 `aa`，密碼 `vncpassword`）：
   ```bash
   grdctl rdp enable
   grdctl rdp set-auth-credential aa vncpassword
   ```
2. 確認服務狀態：
   ```bash
   grdctl status
   ```

### 步驟 3.2：建立 VNC 連線密碼
使用 `x11vnc` 建立無瀏覽器時連線 noVNC 的安全密碼檔案：
```bash
mkdir -p /home/aa/setup_novnc
x11vnc -storepasswd YOUR_VNC_PASSWORD /home/aa/setup_novnc/vnc_passwd
```
*(請將 `YOUR_VNC_PASSWORD` 替換為您要設定的 VNC 連線密碼)*

---

## 4. 指令與腳本檔案

我們在 `/home/aa/setup_novnc` 目錄下準備了兩個主要腳本。

### 4.1 橋接啟動腳本 (`/home/aa/setup_novnc/start_bridge.sh`)
此腳本負責初始化虛擬顯示器、剪貼簿同步工具、VNC 伺服器、RDP 用戶端與 websockify：

```bash
#!/bin/bash

# 清理舊有程序
killall xfreerdp Xvfb x11vnc websockify autocutsel 2>/dev/null
sleep 1

# 設定虛擬顯示器編號並清除 Wayland 環境變數
export DISPLAY=:99
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE

echo "Starting Xvfb on $DISPLAY..."
Xvfb :99 -screen 0 2560x1600x24 > /tmp/xvfb.log 2>&1 &
sleep 1

# 啟動 autocutsel 同步 X11 與 VNC 剪貼簿
echo "Starting autocutsel..."
autocutsel -selection CLIPBOARD -fork
autocutsel -selection PRIMARY -fork

# 預先註冊並套用預設的 1280x720 解析度
/home/aa/setup_novnc/set_resolution.sh 1280x720

# 啟動 x11vnc 伺服器
echo "Starting x11vnc..."
x11vnc -display :99 -forever -shared -rfbauth /home/aa/setup_novnc/vnc_passwd -rfbport 5900 -bg -o /tmp/x11vnc.log 2>&1

# 在背景循環啟動 xfreerdp 用戶端連線至本機 RDP
echo "Starting FreeRDP client to local RDP..."
(
  while true; do
    xfreerdp /v:127.0.0.1:3389 /u:aa /p:vncpassword /cert:ignore /dynamic-resolution /f +auto-reconnect +clipboard +decorations +fonts +menu-anims +window-drag >> /tmp/xfreerdp.log 2>&1
    sleep 2
  done
) &

# 啟動 websockify (noVNC 代理轉接)
echo "Starting websockify on port 6080..."
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &

echo "Bridge started successfully!"
wait
```

### 4.2 解析度切換腳本 (`/home/aa/setup_novnc/set_resolution.sh`)
此腳本用來動態新增解析度模式並套用至虛擬顯示器：

```bash
#!/bin/bash
export DISPLAY=:99
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE

RES=$1
if [ -z "$RES" ]; then
    echo "Usage: $0 <width>x<height>"
    exit 1
fi

MODE="${RES}_60.00"

# 檢查 xrandr 中是否已存在該解析度模式
if ! xrandr | grep -q "$MODE"; then
    WIDTH=$(echo $RES | cut -d'x' -f1)
    HEIGHT=$(echo $RES | cut -d'x' -f2)
    # 使用 cvt 產生 modeline 設定
    MODELINE=$(cvt $WIDTH $HEIGHT | grep Modeline | cut -d' ' -f3-)
    
    if [ -n "$MODELINE" ]; then
        xrandr --newmode "$MODE" $MODELINE 2>/dev/null || true
        xrandr --addmode screen "$MODE" 2>/dev/null || true
    fi
fi

# 套用新的解析度
xrandr --output screen --mode "$MODE"
```

確保以上腳本皆具備執行權限：
```bash
chmod +x /home/aa/setup_novnc/*.sh
```

---

## 5. systemd 使用者服務設定

為了使此橋接服務隨使用者登入自動啟動並在背景運行，我們建立了 systemd 使用者服務。

1. 建立服務設定檔 `/home/aa/.config/systemd/user/novnc-bridge.service`：
   ```ini
   [Unit]
   Description=noVNC to GNOME Wayland Session Bridge
   After=gnome-remote-desktop.service

   [Service]
   Type=simple
   ExecStart=/home/aa/setup_novnc/start_bridge.sh
   Restart=always
   RestartSec=3

   [Install]
   WantedBy=default.target
   ```
2. 啟用並啟動服務：
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable novnc-bridge.service
   systemctl --user start novnc-bridge.service
   ```
3. 檢查服務狀態與日誌：
   ```bash
   systemctl --user status novnc-bridge.service
   journalctl --user -u novnc-bridge.service -f
   ```

---

## 6. 桌面上解析度切換捷徑

為了在 noVNC 網頁中能一鍵調整遠端桌面解析度，我們在 `~/桌面/` (Desktop) 目錄下建立了 `.desktop` 捷徑檔案。

例如建立 `~/桌面/Change_to_1280x720.desktop`：
```ini
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Exec=/home/aa/setup_novnc/set_resolution.sh 1280x720
Name=Change to 1280x720
Comment=Change VNC resolution to 1280x720
Icon=video-display
```

同樣地，可以依需求建立 1600x900、1920x1080 等捷徑：
- `Change_to_1600x900.desktop`
- `Change_to_1920x1080.desktop`

### 啟用桌面捷徑
1. 確保給予捷徑執行權限：
   ```bash
   chmod +x ~/桌面/*.desktop
   ```
2. 在 Ubuntu 桌面上，對各捷徑按滑鼠右鍵，點選「**允許執行**」(Allow Launching)。

---

## 7. 如何連線使用

1. 打開網頁瀏覽器，造訪以下網址：
   ```text
   http://<主機IP>:6080/vnc.html
   ```
2. 點選 **Connect** 並輸入在**步驟 3.2** 中設定的 VNC 密碼。
3. 成功連入後，若要調整解析度，直接按兩下桌面上的解析度切換捷徑（例如 `Change to 1920x1080`），noVNC 視窗便會自動適應新的解析度。
4. 剪貼簿會透過背景執行的 `autocutsel` 自動在您本地瀏覽器與遠端桌面間雙向同步。
