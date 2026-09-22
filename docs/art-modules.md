# 战斗几何、动画与美术配置

正式战斗入口为 `scenes/battle.tscn`，正式美术配置为 `resources/art/ancient_metal_profile.tres`。默认使用古代哑光金属桌面材质及黑底白线卡牌。正式场景唯一指定默认材质；不再提供线框主题。游戏内没有制作台或主题切换入口。

桌面图由 VisualTheme 的可选 `background_texture` 引用，BattleView 调用 renderer 的 `draw_tabletop()` 在完整视口底层等比铺满、居中裁切。ArtBoard 仅绘制前线，卡牌继续使用独立的纯色 `draw_card_background()`，不受桌面贴图影响。微光为静态图片内容，无 Shader 或新增动画。素材来源与本轮状态见 [桌面记录](../resources/art/ancient-metal-v1.md)。

## 独立配置

BattleView 分别持有 `geometry`、`motion`、`profile`。几何使用 `resources/art/battle_geometry.tres`，包含布局、模板、文字槽、命中及插入预览；动画使用 `resources/presentation/basic_motion.tres`，定义阶段和时长。ArtProfile 仅组合 VisualTheme 和可选插画资源；VisualTheme 引用背景纹理、SurfaceStyle 与通用表面渲染器，不持有布局或模板。SurfaceStyle 集中字体、颜色、面板与线条样式；geometry 和 motion 不随材质变化。

更换外观不能改变几何、命中、规则或动画时序。通用 `set_profile()` 和启动脚本 `-Profile` 参数保留，仅显式传入时覆盖正式场景。`geometry_debug`／启动参数 `-GeometryDebug` 是独立显示开关：DisplayProfile 解析固定黑白样式，屏蔽所有内置纹理和插画，保留源 profile 不变；所有卡牌、控件、箭头及动画使用同一解析结果。需要可变配置副本时使用 `duplicate_deep(Resource.DEEP_DUPLICATE_ALL)`，不修改共享资源。

## 保留插画

[素材记录](../resources/art/candidates/README.md)列出六张用户已认可的插画：轻步兵 v2、机枪兵 v4、轻坦 v4、榴弹炮 v2、战斗机 v2、轰炸机 v8。各自保留生成原图、1024 方形母图、认可记录、裁切预览及报告，均未映射到游戏卡牌。

## 共用几何与取景

几何使用逻辑视口设计坐标，统一缩放居中。测量依据见 [KARDS 对照资料](references/kards/README.md)及同目录 geometry-baseline.json。布局与命中使用同一套模板，扇形手牌按实际旋转形状命中，九张手牌均保留安全命中点。

工作台保留独立编辑、收藏存储和图片导入功能。卡牌使用独立线框检查显示及战斗共用模板，直接构造不含生产图片引用的显示配置；导入图片在完整卡／场上卡各自的独立取景窗口显示，保持对应图窗宽高比，焦点为源图 0—1 坐标，缩放后裁切不超出源图。旧收藏的兵种来源记录仍可读取，但不加载内置图片；新卡默认无图。工作台不加入战斗、不注册卡牌定义、不修改用户原始图片。

## 验证与证据

运行 `./tools/verify.ps1 -Label prototype -Art -Workshop` 验证资源读取、配置隔离、战斗真实输入、动画及独立工作台。布局没有变更时不额外运行八尺寸矩阵。

`_mcp_state().presentation` 保留 profile_id，render_mode 为 material 或 geometry_debug；background_texture 是实际可见背景路径，检查模式为空。material_fingerprint 表示源材质，appearance_fingerprint 表示实际显示配置；geometry_fingerprint 与 motion_fingerprint 独立。纹理指纹包含资源路径与尺寸，不是图片内容哈希。截图旁同名 `.png.json` 记录 run_id、实际配置、视口与局面。自动验证、视觉审阅、素材认可及人工试玩分别记录。

几何检查样式独立存放于 `resources/art/geometry_debug_style.tres`，只含黑白调试表面数据，不含 ArtProfile、贴图或插画；正式材质使用 `surface_style.tres`，两者不共享可变样式资源。
