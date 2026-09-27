#!/bin/sh
# Regenerate Sources/LayaGRPC from Protos/laya.proto.
# Requires: protoc (brew install protobuf) and protoc-gen-grpc-swift
# (swift build -c release --product protoc-gen-grpc-swift in a grpc-swift
# clone; the binary is then at .build/release/protoc-gen-grpc-swift).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
GRPC_SWIFT=${GRPC_SWIFT:-/tmp/spmtest/grpc-swift}
GEN=$HERE/Sources/LayaGRPC/Generated
mkdir -p "$GEN" "$HERE/Sources/LayaGRPC/Protos"
cp "$HERE/Protos/laya.proto" "$HERE/Sources/LayaGRPC/Protos/laya.proto"
protoc \
  --plugin=protoc-gen-grpc-swift="$GRPC_SWIFT/.build/release/protoc-gen-grpc-swift" \
  --plugin=protoc-gen-swift="$GRPC_SWIFT/.build/release/protoc-gen-swift" \
  --proto_path="$HERE/Protos" \
  --grpc-swift_out=Visibility=Public,Client=true,Server=true:"$GEN" \
  --swift_out="$GEN" \
  "$HERE/Protos/laya.proto"
echo "generated:"; ls -la "$GEN"
