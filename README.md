# 点击驱散 ClickCleanse

## 功能 / Features

- 自动识别你当前职业/专精的驱散技能，绑定到方块上：1 个驱散左键，2 个左/右键，3 个左/右/中键。
  Auto-discovers your dispels and binds them to the square: 1 dispel → left click, 2 → left/right, 3 → left/right/middle.
- 队友血条旁显示可点击方块，出现你能驱散的减益时自动变色并亮起白色描边（魔法天蓝、诅咒亮紫、中毒亮绿、疾病明黄、流血明红），战斗中、副本内同样有效。
  A clickable square beside each party member's health bar turns the debuff type color with a white highlight border (Magic sky blue, Curse purple, Poison green, Disease yellow, Bleed red) — works in combat and instances.
- 显示驱散技能冷却，单击即对队友施放。
  Shows dispel cooldowns; one click casts on that party member.
- 单人与小队中启用，团队中自动隐藏；无驱散能力时自动停用。
  Active solo or in a party, hidden in raids; disables itself if your spec has no dispel.

## 指令 / Commands

```
/ccl left|right|top|bottom    设置方块相对血条的位置（默认 left）
                               Set the square's position relative to the health bar (default left)
/ccl 10-100                   设置方块大小
                               Set the square size
```

## 致谢 / Credits

- [Decursive](https://www.curseforge.com/wow/addons/decursive) — 托管光环覆盖层（AuraContainer）的实现参考
  Referenced for the managed aura overlay (AuraContainer) implementation.
- [SmartDeBuff](https://www.curseforge.com/wow/addons/smartdebuff) — 驱散类型颜色映射（ColorCurve）的实现参考
  Referenced for the dispel-type color mapping (ColorCurve).

## 说明 / Note

本插件为作者个人游玩方便而制作，功能以自身需求为准，不承诺长期维护。
This addon was made for the author's personal convenience; features follow personal needs and long-term maintenance is not guaranteed.
