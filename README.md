# doubao

豆包技能仓库（私有）。当前收录：

## chenzhou-knowledge-search · 郴州知识检索

连接「瀚天知识库」（https://www.ht-think.com）并在对话里检索郴州地方知识：

授权登录（链接只在对话里给出，用户自己点，不自动跳转）→ 轮询授权状态 → 授权成功后输出知识库简介与快速上手提示词 → 检索条目、取结构化事实卡、文稿自检 → 额度不足时给充值链接（https://www.ht-think.com/portal/recharge）。

目录结构：

```
chenzhou-knowledge-search/
├── SKILL.md                     主流程与话术模板
├── scripts/hantian.ps1          连接器（PowerShell 7）
└── references/
    ├── intro-and-prompts.md     简介与示例提示词（取自插件包原文）
    └── tools.md                 7 个 MCP 工具参数与失败码
```

### 加载方式

把 `chenzhou-knowledge-search` 整个目录放进 skills 根目录（如 `workspace/.user_skills/`），调用入口见 SKILL.md 的「动作表」。

### 运行前提

- Windows + PowerShell 7；脚本以 `$PSScriptRoot` 定位，目录可整体搬迁。
- 令牌存于 `%LOCALAPPDATA%\hantian-kb\token.json`，仅本机有效，不入库、不外传。
- 首次使用需在浏览器完成一次 OAuth 授权（scope `library.read`）。
