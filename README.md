# ClickCleanse

一键简化驱散指示器 / A minimal one-click dispel indicator for party frames.

## 功能 / Features

- **自动识别你的驱散技能**（登录、切换专精或天赋时自动更新）。
  **Auto-discovers your class dispels** on login, spec or talent changes.
- 在每个队友的血条旁显示一个可点击的方块，左键/右键/中键分别绑定不同的驱散技能。
  Shows a clickable square next to each party member's health bar; left / right / middle click are bound to different dispels.
- **可驱散减益检测**：方块被减益类型颜色覆盖（魔法蓝、诅咒紫、中毒绿、疾病棕、流血红）。检测由魔兽 12.1 的暴雪托管光环系统完成，**战斗中、副本内同样有效**。
  **Dispellable debuff detection**: the square is covered by the debuff type color (Magic blue, Curse purple, Poison green, Disease brown, Bleed red). Detection runs through WoW 12.1's Blizzard-managed aura system and **works in combat and instances**.
- 鼠标悬停显示队友名称、职业、按键绑定与可检测的减益类型。
  Hovering shows the unit name/class, mouse bindings and the detected dispel types.
- 显示主驱散技能的冷却倒计时。
  Shows the primary dispel's cooldown countdown.
- 单人和小队中启用，团队中自动隐藏。
  Active while solo or in a party; hidden in raids.

## 游戏内效果 / In-game behavior

- 队友干净时：方块显示职业颜色（50% 透明度）背景 + 白色边框。
  Clean unit: class-colored background (50% alpha) with a white border.
- 队友身上出现你能驱散的减益时：方块自动被对应类型的颜色覆盖，无需任何设置。
  When a dispellable debuff appears, the square is automatically covered by the matching type color — no configuration needed.
- 点击方块即可对目标队友施放对应驱散。
  Click the square to cast the matching dispel on that party member.

## 说明 / Notes

- 12.1 的保密光环限制下，插件 Lua 无法再读取队友减益数据，因此声音警报已随旧检测方案一并移除，检测完全由暴雪托管光环容器在引擎内完成。
  Under 12.1's secret-aura restrictions, addon Lua can no longer read party debuff data, so the sound alert was removed along with the old detection scheme; detection is now fully handled by Blizzard's managed aura containers inside the engine.
- 当前职业/专精没有友方驱散技能时，插件会完全停用。
  If your class/spec has no friendly dispel, the addon disables itself entirely.

## 调试 / Debug

```
/cc debug    -- 切换调试输出 / toggle debug output
/cc 30       -- 设置方块大小 (10-100) / set square size
/cc          -- 手动刷新 / manual refresh
```
