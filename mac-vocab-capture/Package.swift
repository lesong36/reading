// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "VocabCapture",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "VocabCapture", targets: ["VocabCapture"])],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .executableTarget(
      name: "VocabCapture", dependencies: ["CSQLite"],
      resources: [.copy("Resources/PrimaryMathTags.json"), .copy("Resources/MathSkills"), .copy("Resources/MathTeachingReview"), .copy("Resources/AnswerRenderer")]),
    .testTarget(name: "VocabCaptureTests", dependencies: ["VocabCapture"], resources: [.copy("Fixtures")]),
  ]
)
