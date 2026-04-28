# Anyrouter Keepalive

定时对 Anyrouter Claude API 中转站的多账号执行健康检查（保活），通过 GitHub Actions 自动运行，让账号在调度队列中保持活跃状态，从而在使用时获得更高优先级。

## 工作原理

Anyrouter 的调度策略疑似为**账号级先来先用**。如果账号长时间没有请求，可能在队列中失去优先级。本项目在凌晨低峰期定时发起轻量 Claude API 调用，让账号保持活跃。

- 每天 **UTC 18:00（北京时间 02:00）** 启动一个 GitHub Actions 容器
- 容器内部每 **50 分钟** 轮询一遍所有 token（避免 6 小时限制）
- 每个 token 发送一条随机的真实工程提问，使用 `claude -p` 模式
- 输出每个 token 的成功/失败结果
- 可选通过 QQ 邮箱发送汇总报告

## 快速开始

### 1. Fork 仓库

Fork 本仓库到你的 GitHub 账号下。

### 2. 配置 Secrets

在仓库的 **Settings → Secrets and variables → Actions** 中添加：

| Secret 名称 | 说明 | 是否必需 |
|---|---|---|
| `ANYROUTER_TOKENS` | 你的 Anyrouter token，每行一个 | ✅ 必需 |
| `QQ_EMAIL` | QQ 邮箱地址，用于接收报告 | ❌ 可选 |
| `QQ_SMTP_AUTH_CODE` | QQ 邮箱 SMTP 授权码 | ❌ 可选 |

**ANYROUTER_TOKENS 格式：**
```
sk-ant-xxx111
sk-ant-xxx222
sk-ant-xxx333
```

### 3. 启用 Actions

进入 **Actions** 页面，点击 **"I understand my workflows, go ahead and enable them"**。

工作流会自动按 cron 计划运行。你也可以手动触发：Actions → Anyrouter Keepalive → **Run workflow**。

## 本地运行

### 本地单次测试

```bash
# 设置 token
export ANYROUTER_TOKENS="sk-ant-your-token-here"

# 运行单 token 测活
bash scripts/keepalive.sh "$ANYROUTER_TOKENS"
```

### 本地批量运行

```bash
# 方式 1：使用环境变量
export ANYROUTER_TOKENS="sk-ant-xxx111
sk-ant-xxx222"
export QQ_EMAIL="yourname@qq.com"
export QQ_SMTP_AUTH_CODE="your_auth_code"
bash scripts/run-all.sh

# 方式 2：使用 .env 文件
cp .env.example .env
# 编辑 .env 填入你的配置
bash scripts/run-all.sh
```

### 本地单次快速测试（跳过 50 分钟等待）

```bash
export ANYROUTER_TOKENS="sk-ant-test"
MAX_DURATION_SEC=60 bash scripts/run-all.sh
```

## 运行测试

```bash
# 安装 bats（如果未安装）
npm install -g bats

# 运行测试
bats tests/
```

## 定时说明

| 时区 | 启动时间 |
|---|---|
| UTC | 18:00 |
| 北京时间 (UTC+8) | 02:00 |

容器启动后内部每 50 分钟轮询一轮，约运行 5 小时 58 分钟后自动退出（配合 GitHub Actions 的 6 小时超时限制）。

## 文件结构

```
├── .github/workflows/keepalive.yml   # GitHub Actions 工作流
├── scripts/
│   ├── keepalive.sh                   # 核心脚本：单 token 测活
│   ├── run-all.sh                     # 批量运行器：遍历 token + 内部循环
│   └── prompts.txt                    # 工程 prompt 池（防检测）
├── tests/
│   └── test_keepalive.bats            # BATS 测试套件
├── .env.example                       # 本地配置模板
└── README.md
```

## 注意事项

- **不要滥用**：本脚本仅在凌晨低峰期运行，频率合理（每 50 分钟一次），不会对 Anyrouter 造成压力
- **遵守条款**：请遵守 Anyrouter 的使用条款和服务协议
- **频率控制**：token 之间间隔 30 秒（带随机抖动），避免触发限流
- **成本**：每次测活使用 haiku 模型，单个 token 单次成本极低（约 $0.001）
- **邮箱配置**：QQ 邮箱的 SMTP 授权码请在 QQ 邮箱 → 设置 → 账号 → POP3/IMAP/SMTP 服务 中生成
