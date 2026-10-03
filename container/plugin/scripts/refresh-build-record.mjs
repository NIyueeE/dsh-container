#!/usr/bin/env node
// dsh-container 构建期产物后处理 #3: 刷新客户端构建记录。
//
// 上游 `build:official` 会在写完所有客户端产物后落下
// `.dsh-build/client-build-environment.json`(公共环境 + 全部产物的 sha256 摘要)。
// 我们的两个后处理(抽图、minify)在它之后改产物字节, 于是记录里的摘要必然失配 ——
// 上游的 `readClientBuildRecord()` 会直接抛
// "client artifacts differ from .dsh-build/client-build-environment.json"
// (发布工具链 scripts/release/* 与 apps/web 的构建产物 e2e 都走这个校验)。
//
// 这里只重算摘要: 环境字段沿用原记录 —— 产物里嵌入的公共值一个字节都没变, 变的只是
// 字节表示。写盘后立即用上游自己的 readClientBuildRecord() 复核一遍。
//
// 用法: node --experimental-strip-types refresh-build-record.mjs [dsh-root]
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const DEFAULT_ROOT = '/opt/deepseek-harness'
const root = resolve(process.argv[2] ?? DEFAULT_ROOT)
const upstream = await import(pathToFileURL(join(root, 'scripts/client-build-environment.ts')).href)

const recordPath = join(root, upstream.CLIENT_BUILD_RECORD_PATH)
const previous = JSON.parse(readFileSync(recordPath, 'utf8'))
const record = upstream.writeClientBuildRecord(root, previous.environment)
const verified = upstream.readClientBuildRecord(root)
if (verified.artifacts.sha256 !== record.artifacts.sha256) {
  console.error('[refresh-record] refreshed record does not verify against the artifacts')
  process.exit(1)
}

console.log(
  `[refresh-record] ${upstream.CLIENT_BUILD_RECORD_PATH}: ${String(record.artifacts.fileCount)} artifacts, `
  + `sha256 ${record.artifacts.sha256} (verified, environment preserved)`,
)
