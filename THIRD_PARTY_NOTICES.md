# Third-party components

Kestrel's original code is MIT licensed. Dependency licenses and notices remain applicable; this file does not relicense them or grant rights to redistribute Google Play images.

## Android emulator protocol subset

`Sources/KestrelStream/emulator_frames.proto` adapts image and keyboard messages and screenshot/keyboard RPCs from Android SDK `emulator/lib/emulator_controller.proto`. The full Apache-2.0 text is included in [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt) and packaged with the app.

Copyright (C) 2018 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0 . Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

Modifications: only getScreenshot, streamScreenshot, sendKey and the fields used by Kestrel are retained; unused image wire fields are reserved. No server implementation is generated.

## Native streaming dependencies

Pinned direct dependencies: grpc-swift-2 2.4.4, grpc-swift-nio-transport 2.11.0, grpc-swift-protobuf 2.5.0, swift-protobuf 1.39.0. Their upstream LICENSE and NOTICE files, plus those of resolved transitive dependencies in Package.resolved, must accompany any redistributed build that includes them. `scripts/build-app.sh` copies these LICENSE and NOTICE files into `Kestrel.app/Contents/Resources/ThirdPartyNotices/` for every build, and the release DMG contains that app. A full transitive vulnerability audit has not been performed; the notice copy is not a legal review.

## Android Emulator and SDK

Kestrel does not include or redistribute the Android Emulator, Android SDK tools or any Android system image. They are downloaded from Google by `kestrel setup` (or the app's first-run setup) under Google's own licence terms, which the setup accepts on the user's behalf through the official `sdkmanager`. Google Play system images may not be redistributed.

## Research credits

Kestrel was researched and built with [Cana.build](https://cana.build) using its REA mod, based on the open-source [REA](https://github.com/morluto/rea) project. No REA code is included in this repository.
