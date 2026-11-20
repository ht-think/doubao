#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""郴州知识检索 · 登录与令牌管理（零第三方依赖，纯标准库）。

命令：
  python h_auth.py status    检查连接状态 → connected(exit 0) / disconnected(exit 1)
                             有待确认授权码时会自动续查一次（等同 poll 一次）
  python h_auth.py login     发起设备授权：立即输出登录链接并退出（约 2 秒，不阻塞）
  python h_auth.py wait      轮询等待授权完成（供后台任务使用，最长 9.5 分钟）
                             → 已连接(0)/被拒(2)/过期或超时(3)
  python h_auth.py check     续查一次待确认授权码 → 已连接(0)/尚未授权(6)/被拒(2)/过期(3)
  python h_auth.py logout    清除本地令牌与待确认授权码，并尽力吊销

令牌落盘：~/.hantian-skill/token.json（0600），含 access/refresh token 与过期时间。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE_URL = os.environ.get("HT_SKILL_BASE", "https://www.ht-think.com").rstrip("/")
TOKEN_PATH = os.environ.get("HT_SKILL_TOKEN",
                            os.path.join(os.path.expanduser("~"), ".hantian-skill", "token.json"))
CLIENT_ID = "ht-skill"
WAIT_MAX_SECONDS = 570          # wait 最长轮询 9.5 分钟（设备码 TTL 10 分钟，留余量）
PENDING_PATH = os.path.join(os.path.dirname(TOKEN_PATH) or os.path.expanduser("~"), "pending.json")


def _req(method, path, data=None, headers=None, timeout=15):
    url = BASE_URL + path
    if isinstance(data, dict):
        body = urllib.parse.urlencode(data).encode()
    else:
        body = data
    req = urllib.request.Request(url, data=body, method=method,
                                 headers=headers or {})
    opener = urllib.request.build_opener()
    try:
        r = opener.open(req, timeout=timeout)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)


def load_token():
    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_token(tok):
    d = os.path.dirname(TOKEN_PATH)
    if d:
        os.makedirs(d, exist_ok=True)
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(tok, f, ensure_ascii=False)


def drop_token():
    try:
        os.remove(TOKEN_PATH)
        return True
    except OSError:
        return False


def mask(s):
    """日志/回显脱敏：首尾各 4 位。"""
    if not s or len(s) <= 8:
        return "****"
    return s[:4] + "****" + s[-4:]


def try_refresh(tok):
    """静默续签一次。成功返回新 token dict，失败 None。"""
    if not tok or not tok.get("refresh_token"):
        return None
    st, body = _req("POST", "/oauth/token", {
        "grant_type": "refresh_token", "client_id": CLIENT_ID,
        "refresh_token": tok["refresh_token"]})
    if st != 200:
        return None
    try:
        d = json.loads(body)
    except Exception:
        return None
    if "access_token" not in d:
        return None
    now = int(time.time())
    return {"access_token": d["access_token"], "refresh_token": d["refresh_token"],
            "expires_at": now + int(d.get("expires_in", 3600)),
            "refresh_expires_at": now + int(d.get("refresh_expires_in", 0)),
            "scope": d.get("scope", "library.read")}


def check_remote(tok):
    """远端验活：200 → connected；401 → 尝试续签后复检一次。返回 (connected, tok)。"""
    if not tok:
        return False, None
    st, _ = _req("GET", "/api/v1/library_stats",
                 headers={"Authorization": "Bearer " + tok["access_token"]})
    if st == 200:
        return True, tok
    if st == 401:
        nt = try_refresh(tok)
        if nt:
            save_token(nt)
            st, _ = _req("GET", "/api/v1/library_stats",
                         headers={"Authorization": "Bearer " + nt["access_token"]})
            if st == 200:
                return True, nt
    return False, tok


def _poll_pending_once():
    """status 内置的一次授权续查：有待确认授权码时轮询一次。

    返回 "connected"（已换到令牌）／"pending"（仍未授权）／None（无授权单或已作废）。
    """
    p = load_pending()
    if not p:
        return None
    if int(time.time()) - int(p.get("started_at", 0)) > 600:
        drop_pending()
        return None
    rc, tok, _ = _poll_once(p["device_code"])
    if rc == 0:
        save_token(tok)
        drop_pending()
        return "connected"
    if rc in (2, 3):
        drop_pending()
        return None
    return "pending"


def cmd_status():
    tok = load_token()
    ok, _ = check_remote(tok)
    if ok:
        print("connected")
        return 0
    if _poll_pending_once() == "connected":
        print("connected")
        return 0
    print("disconnected")
    return 1


def _save_pending(d):
    """前台等待结束后保存待确认授权码（device_code TTL 10 分钟内仍可用 check 续查）。"""
    dd = os.path.dirname(TOKEN_PATH)
    if dd:
        os.makedirs(dd, exist_ok=True)
    fd = os.open(PENDING_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"device_code": d["device_code"], "user_code": d.get("user_code", ""),
                   "verification_url": d.get("verification_url", ""),
                   "interval": max(5, int(d.get("interval", 5))),
                   "started_at": int(time.time())}, f, ensure_ascii=False)


def load_pending():
    try:
        with open(PENDING_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def drop_pending():
    try:
        os.remove(PENDING_PATH)
    except OSError:
        pass


def _poll_once(device_code):
    """轮询一次。返回 (rc, token_dict or None, err)。rc: 0 成功 / 1 pending / 2 拒 / 3 过期。"""
    st, body = _req("POST", "/api/device/poll", {"device_code": device_code})
    if st == 200:
        tk = json.loads(body)
        now = int(time.time())
        return 0, {"access_token": tk["access_token"],
                   "refresh_token": tk["refresh_token"],
                   "expires_at": now + int(tk.get("expires_in", 3600)),
                   "refresh_expires_at": now + int(tk.get("refresh_expires_in", 0)),
                   "scope": tk.get("scope", "library.read")}, ""
    try:
        err = json.loads(body).get("error", "")
    except Exception:
        err = ""
    if err == "authorization_pending":
        return 1, None, err
    if err == "slow_down":
        return 1, None, err
    if err == "access_denied":
        return 2, None, err
    return 3, None, err


def cmd_login():
    """发起设备授权：立即输出登录链接并退出（不阻塞），结果由 wait/check 续接。"""
    st, body = _req("POST", "/api/device/start")
    if st != 200:
        print("无法发起登录（服务不可达或过于频繁）。请稍后重试。")
        return 3
    try:
        d = json.loads(body)
    except Exception:
        print("登录服务响应异常，请稍后重试。")
        return 3
    _save_pending(d)
    print("请先登录以连接瀚天知识库，登录后我会自动继续：")
    print()
    print("👉 [打开授权链接完成登录（桌面/手机浏览器均可）](%s)" % d["verification_url"])
    print()
    print("授权码：%s（如页面要求输入时填写）" % d["user_code"])
    print("授权进行中：请打开上面的链接完成登录，完成后我会自动继续（无需回复\"已登录\"）。", flush=True)
    return 0


def cmd_wait():
    """轮询等待授权完成（供后台任务使用）。exit 0 已连接 / 2 被拒 / 3 过期或超时。"""
    p = load_pending()
    if not p:
        print("没有待确认的授权码。请先发起登录。")
        return 3
    interval = max(5, int(p.get("interval", 5)))
    left = p.get("started_at", int(time.time())) + 600 - int(time.time())
    deadline = time.time() + min(WAIT_MAX_SECONDS, max(30, left))
    while time.time() < deadline:
        time.sleep(interval)
        rc, tok, err = _poll_once(p["device_code"])
        if rc == 0:
            save_token(tok)
            drop_pending()
            print("connected")
            return 0
        if rc == 1:
            if err == "slow_down":
                interval += 5
            continue
        if rc == 2:
            drop_pending()
            print("denied：本次授权被拒绝。可重新发起登录。")
            return 2
        drop_pending()
        print("授权码已过期或无效。请重新发起登录。")
        return 3
    drop_pending()
    print("等待超时：授权码已过期。请重新发起登录。")
    return 3


def cmd_check():
    """续查一次待确认授权码：exit 0 已连接 / 2 被拒 / 3 已过期无效 / 6 尚未授权。"""
    p = load_pending()
    if not p:
        print("没有待确认的授权码。请先发起登录。")
        return 3
    st, body = _req("POST", "/api/device/poll", {"device_code": p["device_code"]})
    if st == 200:
        tk = json.loads(body)
        now = int(time.time())
        save_token({"access_token": tk["access_token"],
                    "refresh_token": tk["refresh_token"],
                    "expires_at": now + int(tk.get("expires_in", 3600)),
                    "refresh_expires_at": now + int(tk.get("refresh_expires_in", 0)),
                    "scope": tk.get("scope", "library.read")})
        drop_pending()
        print("connected")
        return 0
    try:
        err = json.loads(body).get("error", "")
    except Exception:
        err = ""
    if err == "authorization_pending":
        print("尚未确认：授权码「%s」仍在有效期内，请打开上一条消息里的授权链接完成登录后回复\"已授权\"。" % p.get("user_code", ""))
        return 6
    if err == "access_denied":
        drop_pending()
        print("denied：本次授权被拒绝。请重新发起登录。")
        return 2
    drop_pending()
    print("授权码已过期或无效。请重新发起登录。")
    return 3


def cmd_logout():
    tok = load_token()
    if tok:
        _req("POST", "/oauth/revoke", {"token": tok["access_token"],
                                       "client_id": CLIENT_ID})
    drop_token()
    drop_pending()
    print("已退出登录。")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        return cmd_status()
    if cmd == "login":
        return cmd_login()
    if cmd == "wait":
        return cmd_wait()
    if cmd == "check":
        return cmd_check()
    if cmd == "logout":
        return cmd_logout()
    print("未知命令：%s（可用：status / login / logout）" % cmd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
