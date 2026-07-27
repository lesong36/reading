# 英语长难句交互阅读解析

可在浏览器（含 **iPad Safari**）直接使用的英语长难句阅读器。

## 在线访问

https://lesong36.github.io/reading/

在 iPad 上用 Safari 打开上述地址即可；也可「添加到主屏幕」当网页 App 用。

## 本版说明（GitHub Pages）

- **无需语音**：线上版已关闭 TTS / 听老师讲按钮。
- **无需本地 Ollama**：默认使用 OpenAI-compatible 云端接口；阅读内置示例与已导入文章的解析时，不需要配置任何模型。
- **预置书架**：首次打开会自动加载 RFD1/2/3、四上预置教材；若书架为空，也可点「加载预置教材」。
- **分析新文章 / AI 助教**：在「AI 设置」中自行填写兼容接口的 API Key、Base URL、Model。
- **跨设备同步**（可选）：配置 Firebase 后，书架与生词本可在 iPad / 电脑间同步。

## 本地打开

直接用浏览器打开 `index.html`（需能访问 esm.sh / Tailwind / unpkg CDN）。

## 跨设备同步文章和生词本

GitHub Pages 只托管静态网页。跨设备保存书架与生词本需 Firebase Firestore。

1. 在 Firebase Console 新建项目并添加 Web App，复制 config JSON。
2. 开启 Authentication（Email/Password；可选 Google）。
3. 开启 Firestore Database。
4. 网页顶部点「配置云同步」，粘贴 config，保存后刷新。
5. 点「登录同步」，用同一邮箱在各设备登录。

Firestore Rules 示例：

```txt
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /artifacts/{appId}/users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

同步路径：`artifacts/{projectId}/users/{uid}/readerData/library`（字段 `savedArticles`、`vocabBook`）。
