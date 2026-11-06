# 0.3.7 多屏截图与问答置顶

原因：原选择器仅在preferred screen上创建一层选区；从问答窗口点击追加时鼠标位于该屏，因此其他屏幕没有可交互的选区层。

修复：所有NSScreen同时创建独立选区层，preferred仅决定初始键盘焦点；任意屏幕首次鼠标按下均可开始选择，完成时按该屏幕frame换算并关闭全部选区层。继续复用原截图/坐标转换实现。

新增：问答标题栏图钉按钮，切换置顶/取消置顶；置顶状态写入原interfaceDefaults，重开问答继续沿用。置顶后resignKey与应用失活不降级窗口；截图期间仍暂时隐藏，恢复后仍置顶。不新增依赖。

修改：InteractiveScreenRegionSelector.swift、ScreenshotPanel.swift、ScreenshotQuestionPanel.swift、VERSION及对应ScreenRegionTests/ScreenshotQuestionPanelTests。

验证：相关45项，3项跳过，0失败（/tmp/v037-multiscreen-pin.log）；额外启用真实截图测试，实际3块屏幕分别截图成功（/tmp/v037-live-displays-count.log），frame为(0,0,3200,1800)、(3200,-760,1600,2560)、(996,-1148,1532,1148)。模拟三屏测试通过副屏负坐标的真实鼠标事件验证选择结果和全部窗口关闭；置顶回归覆盖失焦、应用切换通知、截图隐藏恢复、重开和取消。

安装：0.3.7已替换/Users/coty/Applications/拾词助手.app，签名及包文件匹配检查通过。旧应用与会话备份在/Users/coty/Library/Application Support/VocabCapture/integration-backups/037-20261105-101004/。安装版图钉已显示并切换为“已置顶”；原问答内容仍在。

边界：一次拖动选区属于一块屏幕；不生成跨两块屏幕拼接截图。真实截图测试验证三屏可读取，未宣称所有显示器排列均进行人工遍历。
