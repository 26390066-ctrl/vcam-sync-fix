名称：构建 VCamSyncGuard.dylib

开启:
  推送:
    分支：[ main ]
工作流触发：

作业:
  构建:
    运行-on: macos-latest
    步骤:
      - uses: actions/checkout@v4

      - name: 编译 VCamSyncGuard.dylib
        run: |
          mkdir -p build
          xcrun -sdk iphoneos clang \
            -arch arm64 \
            -dynamiclib \
            -miphoneos-version-min=12.0 \
            -framework Foundation \
            -framework CoreMedia \
            -框架 AVFoundation \
            -框架 VideoToolbox \
            -o 构建/VCamSyncGuard.dylib \
            VCamSyncGuard.m
          ls -lh build/VCamSyncGuard.dylib
          文件 构建/VCamSyncGuard.dylib

      - 名称：上传构件
        使用：actions/upload-artifact@v4
        使用:
          名称：VCamSyncGuard.dylib
          路径：build/VCamSyncGuard.dylib
          保留天数：90
