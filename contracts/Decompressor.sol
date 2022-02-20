/// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0;
pragma experimental ABIEncoderV2;

import "./interfaces/IDecompressReceiver.sol";

contract Decompressor is IDecompressReceiver {

  mapping (uint24 => address) public receivers;
  mapping (address => uint24) public receiversByAddress;
  uint24 latestReceiver = 0;

  constructor() {
    registerReceiver(address(this));
  }

  function callMethod(uint8 method, bytes memory data) external override {
    if (method == uint8(0)) {
      // decompressSingleBitCall
      this.decompressSingleBitCall(data);
    } else if (method == uint8(1)) {
      // decompressDoubleBitCall
      this.decompressDoubleBitCall(data);
    } else {
      revert('unknown method');
    }
  }

  function registerReceiver(address receiver) public {
    receiversByAddress[receiver] = latestReceiver;
    receivers[latestReceiver++] = receiver;
  }

  function unwrap(bytes memory d) internal pure returns (uint24, uint8, bytes memory) {
    bytes memory b = new bytes(d.length - 4);
    uint24 receiver = uint24(uint8(d[0]) * 2 ** 16) + uint24(uint8(d[1]) * 2 ** 8) + uint24(uint8(d[2]));
    uint8 method = uint8(d[3]);
    uint words = (d.length - 4) / 32;
    uint remaining = (d.length - 4) % 32;
    bytes32 w;
    for (uint x; x < words; x++) {
      assembly {
        w := mload(add(add(d, 36), mul(32, x)))
        mstore(add(b, add(32, mul(x, 32))), w)
      }
    }
    uint start = 4 + words * 32;
    for (uint x = start; x < start + remaining; x++) {
      b[x - 4] = d[x];
    }
    return (receiver, method, b);
  }

  /**
   * Decompress and pass the data to a contract
   **/
  function decompressSingleBitCall(
    bytes calldata data
  ) public {
    bytes memory finalData = decompressSingleBit(data);
    (uint24 receiver, uint8 method, bytes memory d) = unwrap(finalData);
    require(receivers[receiver] != address(0));
    // now pass the finalData to another function
    IDecompressReceiver(receivers[receiver]).callMethod(method, d);
  }

  /**
   * Decompress double bit encoding and pass the data to a contract
   **/
  function decompressDoubleBitCall(
    bytes calldata data
  ) public {
    bytes memory finalData = decompressDoubleBitZero(data);
    (uint24 receiver, uint8 method, bytes memory d) = unwrap(finalData);
    require(receivers[receiver] != address(0));
    // now pass the finalData to another function
    IDecompressReceiver(receivers[receiver]).callMethod(method, d);
  }

  /**
   * A 0 bit indicates a 0 byte
   * A 1 bit indicates a unique byte
   **/
  function decompressSingleBit(
    bytes calldata data
  ) public pure returns (bytes memory) {
    uint8[8] memory masks;
    masks[0] = 1;
    masks[1] = 2;
    masks[2] = 4;
    masks[3] = 8;
    masks[4] = 16;
    masks[5] = 32;
    masks[6] = 64;
    masks[7] = 128;

    // take a 24 bit uint off the front of the data
    uint24 dataLength = uint24(uint8(data[0]) * 2 ** 16) + uint24(uint8(data[1]) * 2 ** 8) + uint24(uint8(data[2]));
    // then a 16 bit uint after that
    uint16 finalLength = uint16(uint16(uint8(data[3])) * 2 ** 8) + uint16(uint8(data[4]));
    uint48 uniqueStart = 5 + dataLength;
    bytes memory finalData = new bytes(finalLength);

    uint48 latestUnique = 0;
    // 1 bits per item
    // do an AND then shift
    // start at a 3 byte offset
    uint8 offset = 5;
    for (uint48 x = offset; x < dataLength + offset; x++) {
      // all zeroes in this byte, skip it
      /* if (uint8(data[x]) == type(uint8).max) continue; */
      for (uint8 y; y < 8; y++) {
        if (8*(x-offset)+y >= finalLength) return finalData;
        // take the current bit and convert it to a uint8
        // use exponentiation to bit shift
        uint8 thisVal = uint8(data[x] & bytes1(masks[y])) / masks[y];
        // if non-zero add the unique value
        if (thisVal == 1) {
          finalData[8*(x - offset)+y] = data[uniqueStart + latestUnique++];
        }
      }
    }
    return finalData;
  }

  function decompressDoubleBitZero(
    bytes calldata data
  ) public pure returns (bytes memory) {
    uint8[4] memory masks;
    // 11000000 = 3
    // 00110000 = 12
    // 00001100 = 48
    // 00000011 = 192
    masks[0] = 3;
    masks[1] = 12;
    masks[2] = 48;
    masks[3] = 192;

    // take a 24 bit uint off the front of the data
    uint24 dataLength = uint24(uint8(data[0]) * 2 ** 16) + uint24(uint8(data[1]) * 2 ** 8) + uint24(uint8(data[2]));
    // then a 16 bit uint after that
    uint16 finalLength = uint16(uint16(uint8(data[3])) * 2 ** 8) + uint16(uint8(data[4]));
    uint48 uniqueStart = 5 + dataLength;

    uint8[2] memory zeroCounts;
    zeroCounts[0] = uint8(data[data.length - 2]);
    zeroCounts[1] = uint8(data[data.length - 1]);

    bytes memory finalData = new bytes(finalLength);
    uint48 latestUnique = 0;
    // 1 bits per item
    // do an AND then shift
    // start at a 3 byte offset
    uint48 zeroOffset = 0;
    for (uint48 x = 5; x < dataLength + 5; x++) {
      // all zeroes in this byte, skip it
      if (uint8(data[x]) == 0) continue;
      for (uint8 y; y < 4; y++) {
        // take the current bit and convert it to a uint8
        // use exponentiation to bit shift
        if (zeroOffset >= finalLength) return finalData;
        uint8 thisVal = uint8(data[x] & bytes1(masks[y])) / uint8(2) ** (y*2);
        // if non-zero add the unique value
        if (thisVal == 0) {
          zeroOffset++;
        } else if (thisVal == 1) {
          finalData[zeroOffset++] = data[uniqueStart + latestUnique++];
        } else if (thisVal == 2) {
          zeroOffset += zeroCounts[0];
        } else if (thisVal == 3) {
          zeroOffset += zeroCounts[1];
        }
      }
    }
    return finalData;
  }

  function bytes32ToBytes(bytes32 input) internal pure returns (bytes memory) {
    // index is every 8 bits
    bytes memory b = new bytes(32);
    assembly {
      mstore(add(b, 32), input)
    }
    return b;
  }
}
