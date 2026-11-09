# beacon_chain
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/os,
  results,
  json_serialization,
  bearssl/rand,
  stew/[io2, byteutils],
  ../spec/[blake3, crypto, keystore],
  ../filepath

export blake3

const
  HashChainSecretFileName* = "hash_chain_secret"
  HashChainLength* = 1 shl 16
  HashChainCheckpointInterval = 256

type
  HashChain* = object
    secret: Eth2Digest
    checkpoints: seq[Eth2Digest]
    hint: int

func compute_hash_chain_commitment*(
    secret: Eth2Digest, length: int): Opt[Eth2Digest] =
  var link = secret
  if link.isZero:
    return Opt.none(Eth2Digest)
  for _ in 0 ..< length:
    link = compute_hash_chain_link(link)
    if link.isZero:
      return Opt.none(Eth2Digest)
  Opt.some(link)

func init*(T: type HashChain, secret: Eth2Digest): T =
  T(secret: secret, hint: HashChainLength)

proc generateHashChainSecret*(rng: var HmacDrbgContext): Eth2Digest =
  Eth2Digest(data: rng.generate(array[32, byte]))

func hashChainSecretPath*(
    hashChainsDir: string, pubkey: ValidatorPubKey): string =
  hashChainsDir / ("0x" & pubkey.toHex())

func hashChainPasswordPath*(
    secretsDir: string, pubkey: ValidatorPubKey): string =
  secretsDir / ("hash_chain_0x" & pubkey.toHex())

proc readHashChainPassword(
    secretsDir: string, pubkey: ValidatorPubKey): Result[KeystorePass, string] =
  let path = hashChainPasswordPath(secretsDir, pubkey)
  let data = readAllChars(path).valueOr:
    return err("Cannot read " & path & ": " & ioErrorMsg(error))
  ok KeystorePass.init(data)

proc saveHashChainSecret*(
    rng: var HmacDrbgContext, hashChainsDir, secretsDir: string,
    pubkey: ValidatorPubKey, secret: Eth2Digest): Result[void, string] =
  let passwordPath = hashChainPasswordPath(secretsDir, pubkey)
  if not fileExists(passwordPath):
    secureCreatePath(secretsDir).isOkOr:
      return err("Cannot create " & secretsDir & ": " & ioErrorMsg(error))
    secureWriteFile(
        passwordPath, rng.generate(array[32, byte]).toHex()).isOkOr:
      return err("Cannot write " & passwordPath & ": " & ioErrorMsg(error))

  let crypto = createHashChainCrypto(
    rng, secret, ? readHashChainPassword(secretsDir, pubkey))
  secureCreatePath(hashChainsDir).isOkOr:
    return err("Cannot create " & hashChainsDir & ": " & ioErrorMsg(error))
  let path = hashChainSecretPath(hashChainsDir, pubkey)
  secureWriteFile(path, Json.encode(crypto)).isOkOr:
    return err("Cannot write " & path & ": " & ioErrorMsg(error))
  ok()

proc loadHashChainSecret*(
    hashChainsDir, secretsDir: string,
    pubkey: ValidatorPubKey): Result[Opt[Eth2Digest], string] =
  ## `none` when no secret is stored, `err` when one is stored but unreadable
  let path = hashChainSecretPath(hashChainsDir, pubkey)
  if not fileExists(path):
    return ok Opt.none(Eth2Digest)
  let data = readAllChars(path).valueOr:
    return err("Cannot read " & path & ": " & ioErrorMsg(error))
  let crypto =
    try:
      Json.decode(data, Crypto)
    except SerializationError as exc:
      return err("Invalid hash chain secret in " & path & ": " & exc.msg)
  let secret = decryptHashChainCrypto(
      crypto, ? readHashChainPassword(secretsDir, pubkey)).valueOr:
    return err("Cannot decrypt " & path & ": " & error)
  ok Opt.some(secret)

func getHashChainReveal*(
    chain: var HashChain, commitment: Eth2Digest): Opt[Eth2Digest] =
  if chain.checkpoints.len == 0:
    var link = chain.secret
    for i in 0 ..< HashChainLength:
      if i mod HashChainCheckpointInterval == 0:
        chain.checkpoints.add link
      link = compute_hash_chain_link(link)

  template searchSegment(segment: int) =
    var link = chain.checkpoints[segment]
    for step in 0 ..< HashChainCheckpointInterval:
      let index = segment * HashChainCheckpointInterval + step
      if index >= HashChainLength:
        break
      let next = compute_hash_chain_link(link)
      if next == commitment:
        chain.hint = index + 1
        return Opt.some(link)
      link = next

  let hintSegment = (chain.hint - 1) div HashChainCheckpointInterval
  for segment in countdown(hintSegment, 0):
    searchSegment(segment)
  for segment in hintSegment + 1 ..< chain.checkpoints.len:
    searchSegment(segment)
  Opt.none(Eth2Digest)
