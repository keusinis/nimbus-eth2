# ponytail: overlay until ethereum-genesis-generator knows EIP-8321; upstream these two template lines then
FROM ethpandaops/ethereum-genesis-generator:6.2.7
RUN printf 'EIP8321_FORK_VERSION: $EIP8321_FORK_VERSION\nEIP8321_FORK_EPOCH: $EIP8321_FORK_EPOCH\n' >> /config/cl/config.yaml
