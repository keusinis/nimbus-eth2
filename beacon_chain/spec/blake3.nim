# beacon_chain
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

# https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf
# Unkeyed, default 32-byte output only.

import ./digest

export digest

const
  BLOCK_LEN = 64
  CHUNK_LEN = 1024
  CHUNK_START = 1'u32
  CHUNK_END = 2'u32
  PARENT = 4'u32
  ROOT = 8'u32
  IV = [
    0x6A09E667'u32, 0xBB67AE85'u32, 0x3C6EF372'u32, 0xA54FF53A'u32,
    0x510E527F'u32, 0x9B05688C'u32, 0x1F83D9AB'u32, 0x5BE0CD19'u32]
  MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

type
  Words8 = array[8, uint32]
  Words16 = array[16, uint32]

func rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

func g(s: var Words16, a, b, c, d: int, mx, my: uint32) {.inline.} =
  s[a] = s[a] + s[b] + mx
  s[d] = rotr(s[d] xor s[a], 16)
  s[c] = s[c] + s[d]
  s[b] = rotr(s[b] xor s[c], 12)
  s[a] = s[a] + s[b] + my
  s[d] = rotr(s[d] xor s[a], 8)
  s[c] = s[c] + s[d]
  s[b] = rotr(s[b] xor s[c], 7)

func round(s: var Words16, m: Words16) {.inline.} =
  g(s, 0, 4, 8, 12, m[0], m[1])
  g(s, 1, 5, 9, 13, m[2], m[3])
  g(s, 2, 6, 10, 14, m[4], m[5])
  g(s, 3, 7, 11, 15, m[6], m[7])
  g(s, 0, 5, 10, 15, m[8], m[9])
  g(s, 1, 6, 11, 12, m[10], m[11])
  g(s, 2, 7, 8, 13, m[12], m[13])
  g(s, 3, 4, 9, 14, m[14], m[15])

func compress(
    cv: Words8, blockWords: Words16, counter: uint64, blockLen: uint32,
    flags: uint32): Words16 =
  var
    s: Words16 = [
      cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
      IV[0], IV[1], IV[2], IV[3],
      uint32(counter), uint32(counter shr 32), blockLen, flags]
    m = blockWords
  for i in 0 ..< 7:
    round(s, m)
    if i < 6:
      var p: Words16
      for j in 0 ..< 16:
        p[j] = m[MSG_PERMUTATION[j]]
      m = p
  for i in 0 ..< 8:
    s[i] = s[i] xor s[i + 8]
    s[i + 8] = s[i + 8] xor cv[i]
  s

func loadBlock(data: openArray[byte], offset, len: int): Words16 =
  var buf: array[BLOCK_LEN, byte]
  for i in 0 ..< len:
    buf[i] = data[offset + i]
  for i in 0 ..< 16:
    result[i] =
      uint32(buf[i * 4]) or (uint32(buf[i * 4 + 1]) shl 8) or
      (uint32(buf[i * 4 + 2]) shl 16) or (uint32(buf[i * 4 + 3]) shl 24)

func first8(w: Words16): Words8 =
  for i in 0 ..< 8:
    result[i] = w[i]

func chunkOutput(
    data: openArray[byte], offset, len: int, counter: uint64,
    isRoot: bool): Words16 =
  var
    cv = IV
    pos = 0
  let numBlocks = max(1, (len + BLOCK_LEN - 1) div BLOCK_LEN)
  for i in 0 ..< numBlocks:
    let
      blockLen = min(BLOCK_LEN, len - pos)
      flags =
        (if i == 0: CHUNK_START else: 0'u32) or
        (if i == numBlocks - 1: CHUNK_END or (if isRoot: ROOT else: 0'u32)
         else: 0'u32)
      words = loadBlock(data, offset + pos, blockLen)
    result = compress(cv, words, counter, uint32(blockLen), flags)
    cv = first8(result)
    pos += blockLen

func parentOutput(left, right: Words8, isRoot: bool): Words16 =
  var words: Words16
  for i in 0 ..< 8:
    words[i] = left[i]
    words[i + 8] = right[i]
  compress(
    IV, words, 0, uint32(BLOCK_LEN),
    PARENT or (if isRoot: ROOT else: 0'u32))

func subtreeOutput(
    data: openArray[byte], offset, len: int, counter: uint64,
    isRoot: bool): Words16 =
  if len <= CHUNK_LEN:
    return chunkOutput(data, offset, len, counter, isRoot)
  var leftLen = CHUNK_LEN
  while leftLen * 2 < len:
    leftLen *= 2
  let
    left = first8(subtreeOutput(data, offset, leftLen, counter, false))
    right = first8(subtreeOutput(
      data, offset + leftLen, len - leftLen,
      counter + uint64(leftLen div CHUNK_LEN), false))
  parentOutput(left, right, isRoot)

func blake3*(data: openArray[byte]): Eth2Digest =
  let words = subtreeOutput(data, 0, data.len, 0, true)
  for i in 0 ..< 8:
    result.data[i * 4] = byte(words[i])
    result.data[i * 4 + 1] = byte(words[i] shr 8)
    result.data[i * 4 + 2] = byte(words[i] shr 16)
    result.data[i * 4 + 3] = byte(words[i] shr 24)

# https://github.com/lukassta/consensus-specs/blob/12c8b24bc09b12f62688d439ba20ef00b1fdfe1f/specs/_features/eip8321/beacon-chain.md#hash-chain
const HASH_CHAIN_RANDAO_DST* = "HASH_CHAIN_RANDAO"

func compute_hash_chain_link*(value: Eth2Digest): Eth2Digest =
  var data: array[HASH_CHAIN_RANDAO_DST.len + 32, byte]
  for i in 0 ..< HASH_CHAIN_RANDAO_DST.len:
    data[i] = byte(HASH_CHAIN_RANDAO_DST[i])
  data[HASH_CHAIN_RANDAO_DST.len ..< data.len] = value.data
  blake3(data)

func compute_hash_chain_mix*(mix, reveal: Eth2Digest): Eth2Digest =
  var data: array[64, byte]
  data[0 ..< 32] = mix.data
  data[32 ..< 64] = reveal.data
  blake3(data)
