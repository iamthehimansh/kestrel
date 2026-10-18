# Third-party components

Kestrel's original code is MIT licensed. Dependency licenses and notices remain applicable; this file does not relicense them or grant rights to redistribute Google Play images.

## Android emulator protocol subset

`Sources/KestrelStream/emulator_frames.proto` adapts the read-only image messages and screenshot RPCs from Android SDK `emulator/lib/emulator_controller.proto`.

Copyright (C) 2018 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0 . Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

Modifications: only getScreenshot/streamScreenshot and the inline image fields used by Kestrel are retained; unused wire fields are reserved. No server implementation is generated.

## Native streaming dependencies

Pinned direct dependencies: grpc-swift-2 2.4.4, grpc-swift-nio-transport 2.11.0, grpc-swift-protobuf 2.5.0, swift-protobuf 1.39.0. Their upstream LICENSE and NOTICE files, plus those of resolved transitive dependencies in Package.resolved, must accompany any redistributed build that includes them. Packaging integration and a full transitive license/advisory audit remain pending; this development target is not a released installer.
