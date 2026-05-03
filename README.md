# 英语长难句交互阅读解析

一个可直接在浏览器运行的英语长难句阅读器。

## 在线访问

发布到 GitHub Pages 后，访问：

https://lesong36.github.io/reading/

## 本地打开

直接打开 `index.html` 即可使用。

## 说明

- 页面依赖浏览器端 CDN 加载 React、Tailwind、Firebase、Lucide 图标等前端库。
- 本地 Ollama 地址 `http://127.0.0.1:11434` 只会连接当前电脑本机的 Ollama。
- 远程或 OpenAI-compatible 模型配置需要在页面内自行填写 Base URL、Model 和 API Key。

## 跨电脑同步文章和生词本

GitHub Pages 只能发布网页，不能保存每台电脑的个人数据。文章书架和生词本的跨设备同步需要一个云端数据库；本页面支持 Firebase Firestore。

配置步骤：

1. 在 Firebase Console 新建项目。
2. 添加一个 Web App，复制 Firebase config JSON。
3. 开启 Authentication，至少启用 Email/Password 登录方式；如果要用 Google 登录，也启用 Google provider。
4. 开启 Firestore Database。
5. 在网页顶部点击“配置云同步”，粘贴 Firebase config JSON，保存后刷新。
6. 点击“登录同步”，注册或登录同一邮箱账号。

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

同步内容会保存在：

```txt
artifacts/{projectId}/users/{uid}/readerData/library
```

包含两个 JSON 字段：`savedArticles` 和 `vocabBook`。导入/导出 JSON 仍可作为额外备份。
