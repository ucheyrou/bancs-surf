"""Captures d'écran du viewer en émulation iPhone (Chrome headless + DevTools, viewport 393x852 @3x).
Usage : .venv/bin/python tools/shot_iphone.py "index.html" "index.html?spot=la_nord" ...  -> output/../captures/*.png"""
import base64, json, subprocess, sys, time, pathlib, requests, websocket
RACINE = pathlib.Path(__file__).resolve().parent.parent
OUT = RACINE / "captures"; OUT.mkdir(exist_ok=True)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
srv = subprocess.Popen([sys.executable, "-m", "http.server", "8765", "--directory", str(RACINE / "output")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
chrome = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--remote-debugging-port=9333", "--remote-allow-origins=*", "--window-size=500,900", "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(3)
try:
    page = next(t for t in requests.get("http://localhost:9333/json").json() if t["type"] == "page")
    ws = websocket.create_connection(page["webSocketDebuggerUrl"]); mid = 0
    def cmd(method, **params):
        global mid; mid += 1
        ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            r = json.loads(ws.recv())
            if r.get("id") == mid: return r.get("result", {})
    cmd("Emulation.setDeviceMetricsOverride", width=393, height=852, deviceScaleFactor=3, mobile=True)
    cmd("Emulation.setUserAgentOverride", userAgent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
    cmd("Emulation.setTouchEmulationEnabled", enabled=True)
    for i, url in enumerate(sys.argv[1:] or ["index.html"]):
        cmd("Page.navigate", url="http://localhost:8765/" + url); time.sleep(5)
        data = cmd("Page.captureScreenshot", format="png")["data"]
        nom = OUT / f"iphone_{i+1}_{url.split('?')[-1].replace('=', '-').replace('&', '_') if '?' in url else 'carte'}.png"
        nom.write_bytes(base64.b64decode(data)); print(nom)
finally:
    chrome.terminate(); srv.terminate()
