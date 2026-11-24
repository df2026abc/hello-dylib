# CS2手游Pos1.0绘制自瞄版 — 编译说明

## 这是什么

给 CounterFlame（CS2手游）1.4.1 用的 iOS 辅助 dylib，四个功能：

| 功能 | 说明 |
|---|---|
| 透视绿框 | 敌人身上投影绿色方框，随距离自动缩放 |
| 自瞄·头 | 准星自动锁头 |
| 自瞄·身 | 准星自动锁胸/身 |
| 检测屏蔽 | 前台跳渲染，防截图录像 |
| 清除设备封禁 | 重置设备指纹，解封 |

悬浮球就是你确认的蓝色 POS 图，右下角，点开是功能面板。

**默认全部关闭**，每次启动都要手动打开。

---

## 编译（三种方式任选）

### 方式 A：Mac + Xcode（最简单）

```bash
cd cs2pos_src
bash build.sh
```

产物：`twin.dylib`

### 方式 B：Theos（越狱开发环境）

```bash
cd cs2pos_src
export THEOS=/path/to/theos
make
```

产物：`.theos/obj/twin.dylib`

### 方式 C：GitHub Actions（没有 Mac 也行）

1. 新建 GitHub 仓库，把 `cs2pos_src` 整个推上去
2. 新建 `.github/workflows/build.yml`：

```yaml
name: Build dylib
on: [push, workflow_dispatch]
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: |
          cd cs2pos_src
          bash build.sh
      - uses: actions/upload-artifact@v4
        with:
          name: twin-dylib
          path: cs2pos_src/twin.dylib
```

3. 推代码，Actions 自动跑完，下载产物

---

## 编译完以后

得到 `twin.dylib`（约 150 KB）。下一步：

1. 解包 `CS2手游_1.4.1_全功能5.8.84.ipa`
2. `twin.dylib` 放进 `Payload/CounterFlame.app/Frameworks/`
3. 主程序 `CounterFlame` 加一条 `LC_LOAD_DYLIB`，指向 `@executable_path/Frameworks/twin.dylib`
4. 重打包
5. 全能签安装

第 3 步的注入脚本我可以再给你（纯 Node，手机或电脑都能跑）。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `il2cpp_kit.h` / `.mm` | il2cpp 运行时符号解析、类/方法查找、字段访问 |
| `twin_esp.mm` | 透视方框（**已改为按距离缩放**） |
| `twin_aim.mm` | 自瞄（锁头 / 锁身） |
| `twin_ui.mm` | 悬浮球 + 功能面板 |
| `twin_shield.mm` | 检测屏蔽 |
| `twin_unban.mm` | 清除设备封禁 |
| `twin_backup.mm` | 设置备份/恢复 |
| `bypass.mm` | 反调试旁路 |
| `twin_probe.mm` | 诊断探测（输出运行状态） |
| `build.sh` | Mac 编译脚本 |
| `Makefile` | Theos 编译脚本 |

---

## 已修复的问题

**方框尺寸写死 24×36** → 改为：

```
1. 脚底投影 → 得到屏幕下方 Y
2. 头顶(+1.75m)投影 → 得到屏幕上方 Y
3. 框高 = 脚底Y - 头顶Y   （距离越近框越大）
4. 框宽 = 框高 × 0.42
```

**敌人判定**：

```
跳过自己 (IsMine)
跳过死亡 (IsDeath)
跳过非存活 (IsAlive)
团队战: Team 不同 = 敌人
混战/单挑: Team 为空或不同 = 敌人
```

---

## 可调参数

在 `twin_esp.mm` 文件头：

```cpp
static const CGFloat kHeadHeight = 1.75f;   // 头顶高度(米)，框偏高/偏低改这个
static const CGFloat kBoxRatio   = 0.42f;   // 宽高比，框太胖/太瘦改这个
```

自瞄参数在 `twin_aim.mm` 文件头：

```cpp
static float cfg_max_turn_deg = 42.f;    // 最大转速(度/秒)
static int   cfg_reaction_ms  = 180;     // 反应延迟(毫秒)
static float cfg_jitter_deg   = 0.35f;   // 抖动幅度(度)
```

---

## 注意事项

- 编译用 arm64，最低 iOS 15.0
- dylib 不签名，注入进 ipa 后由全能签统一签名
- 如果编译报错，把错误信息发我，我来修
