#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""郴州知识检索 · 业务查询（零第三方依赖，纯标准库）。

命令（与瀚天知识库 MCP 工具一一对应，走 REST /api/v1/*）：
  python h_api.py search <关键词...> [--topic ID] [--domain X] [--limit N]
  python h_api.py get <unit_id> [--full]        # 默认 digest 摘要，--full 取全文
  python h_api.py unit <unit_id>                # 条目事实卡（unit_brief）
  python h_api.py topics [--domain X]           # 主题分类清单
  python h_api.py topic <topic_id|名称>         # 主题概览（topic_brief）
  python h_api.py gate --draft <文件路径> [--query 词]   # 合规自检
  python h_api.py stats                         # 库可用状态

退出码：0 成功｜2 未登录/令牌失效｜4 限流｜5 积分不足（已输出充值引导）｜6 参数/服务异常
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from h_auth import BASE_URL, load_token, save_token, try_refresh  # noqa: E402
import urllib.error                                               # noqa: E402
import urllib.parse                                               # noqa: E402
import urllib.request                                             # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def _req(method, path, data=None, headers=None, timeout=60):
    body = json.dumps(data, ensure_ascii=False).encode("utf-8") if isinstance(data, dict) else data
    req = urllib.request.Request(BASE_URL + path, data=body, method=method,
                                 headers=headers or {})
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)
    except Exception as e:
        return 0, str(e), {}


def _call(tool, args):
    """带一次静默续签重试的工具调用。打印 MCP 同源文本；返回退出码。"""
    tok = load_token()
    if not tok:
        print("尚未登录。请先运行 h_auth.py login 完成登录。")
        return 2
    auth = {"Authorization": "Bearer " + tok["access_token"],
            "Content-Type": "application/json"}
    st, body, hd = _req("POST", "/api/v1/" + tool, args, auth)
    if st == 401:
        nt = try_refresh(tok)
        if nt:
            save_token(nt)
            auth["Authorization"] = "Bearer " + nt["access_token"]
            st, body, hd = _req("POST", "/api/v1/" + tool, args, auth)
    if st == 401:
        print("登录已失效。请重新运行 h_auth.py login。")
        return 2
    if st == 402:
        try:
            d = json.loads(body)
            url = d.get("url") or BASE_URL + "/portal/recharge"
            bal = d.get("balance", "?")
        except Exception:
            url, bal = BASE_URL + "/portal/recharge", "?"
        print()
        print("⚠️ 瀚天积分不足，本次查询未完成。")
        print()
        print("👉 [立即充值瀚天积分，继续查询](%s)" % url)
        print()
        print("充值完成后，请回复\"已充值\"，我会自动继续刚才的查询。（当前余额：%s）" % bal)
        print()
        return 5
    if st == 429:
        try:
            wait = int(hd.get("Retry-After", 30) or 30)
        except Exception:
            wait = 30
        print("查询过于频繁，请 %d 秒后再试。" % wait)
        return 4
    if st != 200:
        print("查询失败（服务异常，错误码 %s）。请稍后重试。" % st)
        return 6
    try:
        result = json.loads(body)
        text = result["content"][0]["text"]
        if result.get("isError"):
            print("查询未成功：%s" % text[:300])
            return 6
    except Exception:
        print("响应解析失败：%s" % body[:300])
        return 6
    print(text)
    return 0


def main():
    p = argparse.ArgumentParser(prog="h_api")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("search")
    sp.add_argument("query", nargs="+")
    sp.add_argument("--topic", dest="topic_id")
    sp.add_argument("--domain")
    sp.add_argument("--limit", type=int, default=10)

    gp = sub.add_parser("get")
    gp.add_argument("unit_id")
    gp.add_argument("--full", action="store_true")

    sub.add_parser("topics").add_argument("--domain")
    bp = sub.add_parser("topic"); bp.add_argument("topic_ref")
    up = sub.add_parser("unit"); up.add_argument("unit_id")
    gp2 = sub.add_parser("gate")
    gp2.add_argument("--draft", required=True, help="待检文稿文件路径")
    gp2.add_argument("--query")
    sub.add_parser("stats")

    a = p.parse_args()
    if a.cmd == "search":
        args = {"query": " ".join(a.query), "limit": a.limit}
        if a.topic_id:
            args["topic_id"] = a.topic_id
        if a.domain:
            args["domain"] = a.domain
        return _call("search_units", args)
    if a.cmd == "get":
        return _call("get_unit", {"unit_id": a.unit_id,
                                  "digest": not a.full})
    if a.cmd == "unit":
        return _call("unit_brief", {"unit_id": a.unit_id})
    if a.cmd == "topics":
        args = {}
        if a.domain:
            args["domain"] = a.domain
        return _call("list_topics", args)
    if a.cmd == "topic":
        args = {"topic_id": a.topic_ref} if a.topic_ref[:4].upper().startswith("HT-") \
            else {"topic": a.topic_ref}
        return _call("topic_brief", args)
    if a.cmd == "gate":
        try:
            with open(a.draft, "r", encoding="utf-8") as f:
                draft = f.read()
        except OSError as e:
            print("无法读取文稿：%s" % e)
            return 6
        args = {"draft": draft}
        if a.query:
            args["query"] = a.query
        return _call("gate_check", args)
    if a.cmd == "stats":
        return _call("library_stats", {})
    return 6


if __name__ == "__main__":
    sys.exit(main())
