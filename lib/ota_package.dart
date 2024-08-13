// ignore_for_file: annotate_overrides, avoid_print, prefer_const_constructors

// Import necessary libraries
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

// Abstract class defining the structure of an OTA package
abstract class OtaPackage {
  /// Method to update firmware.
  ///
  /// [device]: The Bluetooth device to update firmware on.
  /// [updateType]: The type of update operation.
  /// [firmwareType]: The type of firmware to update.
  /// [uri]: The file path or URL of the firmware binary (optional).
  Future<void> updateFirmware(
      BluetoothDevice device,
      UpdateType updateType,
      FirmwareType firmwareType,
      {String? uri}
  );

  /// Property to track firmware update status
  bool firmwareUpdate = false;

  /// Stream to provide progress percentage
  Stream<int> get percentageStream;
}

enum UpdateType {
  espidf,
  arduino,
}

enum FirmwareType {
  assets,
  filepicker,
  url,
}

/// A class responsible for handling BLE repository operations.
class BleRepository {
  // Write data to a Bluetooth characteristic
  Future<void> writeDataCharacteristic(
      BluetoothCharacteristic characteristic, Uint8List data) async {
    await characteristic.write(data);
  }

  /// Read data from a Bluetooth characteristic
  Future<List<int>> readCharacteristic(
      BluetoothCharacteristic characteristic) async {
    return await characteristic.read();
  }

  /// Request a specific MTU size from a Bluetooth device
  Future<void> requestMtu(BluetoothDevice device, int mtuSize) async {
    await device.requestMtu(mtuSize);
  }
}

/// Implementation of OTA package for ESP32
class Esp32OtaPackage implements OtaPackage {
  /// Properties
  int part = 16000; // Part size for firmware update
  final BluetoothCharacteristic
      notifyCharacteristic; // Characteristic for notifications
  final BluetoothCharacteristic
      writeCharacteristic; //Characteristic for writing data
  StreamSubscription?
      subscription; // declare subscription as an instance variable
  bool firmwareUpdate = false; // Flag indicating firmware update status

  final StreamController<int> _percentageController =
      StreamController<int>.broadcast();

  @override
  Stream<int> get percentageStream =>
      _percentageController.stream; // Getter for percentage update stream

  /// Constructor
  Esp32OtaPackage(this.notifyCharacteristic, this.writeCharacteristic);

  /// Function to read binary firmware file and split it into chunks
  Future<List<Uint8List>> _readBinaryFile(String filePath, int mtuSize) async {
    print("In binary file read and path is $filePath");
    ByteData fileData = await rootBundle.load(filePath);
    List<int> bytes = fileData.buffer.asUint8List();
    print(Uint8List.fromList(bytes));
    List<Uint8List> firmwareData = [];
    // Split file data into chunks based on MTU size
    for (int i = 0; i < bytes.length; i += mtuSize) {
      int end = i + mtuSize;
      if (end > bytes.length) {
        end = bytes.length;
      }
      firmwareData.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return firmwareData; // Return firmware data chunks
  }

  /// Convert Uint8List to List<int>
  List<int> uint8ListToIntList(Uint8List uint8List) {
    return uint8List.toList();
  }

  /// Get firmware chunks from file picker
  Future<List<Uint8List>> _getFirmwareFromPicker(int mtuSize) async {
    print("Mtu size in file picker is $mtuSize");
    
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      print("File was empty");
      return []; // Return an empty list when no file is picked
    }

    final file = result.files.first;
    print("Read the file :$file");
    try {
      final firmwareData = await _openFileAndGetFirmwareData(file, mtuSize);

      if (firmwareData.isEmpty) {
        throw 'Empty firmware data. Please select a valid firmware file.';
      }

      return firmwareData;
    } catch (e) {
      throw 'Error getting firmware data: $e';
    }
  }

  /// Get firmware chunks from file picker
  Future<Uint8List> _getFirmwareFromPickerArduino(int mtuSize) async {
    print("Mtu size in fie picker for arduino firmware is $mtuSize");
    final Uint8List binfiledata;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      //allowedExtensions: ['bin'],
    );

    if (result == null || result.files.isEmpty) {
      print("File was empty");
      return Uint8List(0); // Return an empty list when no file is picked
    }

    final file = result.files.first;
    print("Read the file :$file");
    try {
      final bytes = await File(file.path!).readAsBytes();
      binfiledata = Uint8List.fromList(bytes);

      return binfiledata;
    } catch (e) {
      throw 'Error getting firmware data: $e';
    }
  }
  Future<List<Uint8List>> _getFirmwareFromUrl(String url, int mtuSize) async {
    try {
      final response =
      await http.get(Uri.parse(url)).timeout(Duration(seconds: 10));

      /// Check if the HTTP request was successful (status code 200)
      if (response.statusCode == 200) {
        final List<int> bytes = response.bodyBytes;
        final int chunkSize = mtuSize - 3;
        List<Uint8List> chunks = [];
        for (int i = 0; i < bytes.length; i += chunkSize) {
          int end = i + chunkSize;
          if (end > bytes.length) {
            end = bytes.length;
          }
          Uint8List chunk = Uint8List.fromList(bytes.sublist(i, end));
          chunks.add(chunk);
        }
        return chunks;
      } else {
        /// Handle HTTP error (e.g., status code is not 200)
        throw 'HTTP Error: ${response.statusCode} - ${response.reasonPhrase}';
      }
    } catch (e) {
      /// Handle other errors (e.g., timeout, network connectivity issues)
      throw 'Error fetching firmware from URL: $e';
    }
  }

  Future<Uint8List> _getFirmwareFromUrlArduino(String url, int mtuSize) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(Duration(seconds: 10));

      /// Check if the HTTP request was successful (status code 200)
      if (response.statusCode == 200) {
        final List<int> bytes = response.bodyBytes;
        final int chunkSize = mtuSize - 3;
        Uint8List firmware = Uint8List(0); // Initialize an empty Uint8List
        for (int i = 0; i < bytes.length; i += chunkSize) {
          int end = i + chunkSize;
          if (end > bytes.length) {
            end = bytes.length;
          }
          Uint8List chunk = Uint8List.fromList(bytes.sublist(i, end));
          firmware = Uint8List.fromList([...firmware, ...chunk]); // Concatenate the chunks
        }
        return firmware;
      } else {
        /// Handle HTTP error (e.g., status code is not 200)
        throw 'HTTP Error: ${response.statusCode} - ${response.reasonPhrase}';
      }
    } catch (e) {
      /// Handle other errors (e.g., timeout, network connectivity issues)
      throw 'Error fetching firmware from URL: $e';
    }
  }

  /// Open file, read bytes, and split into chunks
  Future<List<Uint8List>> _openFileAndGetFirmwareData(
      PlatformFile file, int mtuSize) async {
    final bytes = await File(file.path!).readAsBytes();
    List<Uint8List> firmwareData = [];
    print('Before Dividing firmware data into chunks');
    for (int i = 0; i < bytes.length; i += mtuSize) {
      int end = i + mtuSize;
      if (end > bytes.length) {
        end = bytes.length;
      }
      firmwareData.add(Uint8List.fromList(bytes.sublist(i, end)));
    }
    return firmwareData;
  }

  /// sendPart function which is used to send parts to the esp32
  Future<void> sendPart(int position, Uint8List data, int mtuSize) async {
    final bleRepo = BleRepository();
    int start = (position * part);
    int end = (position + 1) * part;
    if (data.length < end) {
      end = data.length;
    }
    int parts = (end - start) ~/ mtuSize;
    print("Parts are $parts");
    for (int i = 0; i < parts; i++) {
      print(
          "created $i parts"); //<------------------------------ Print to debug
      Uint8List toSend = Uint8List(mtuSize + 2);
      toSend[0] = 0XFB;
      toSend[1] = i;
      int variable = 2;
      for (int y = 0; y < mtuSize; y++) {
        /// toSend.append(data[(position * PART) + (MTU * i) + y])

        int x = data[(position * part) + (mtuSize * i) + y];
        Uint8List list2 = Uint8List.fromList([x]);

        /// Copy the contents of list1 into the beginning of combinedList
        toSend.setRange(variable, variable + list2.length, list2);
        variable = variable + list2.length;
      }

      /// print statement below should be replaced with actual sending code

      print("Before writing data, to send length is ${toSend.length}");
      await bleRepo.writeDataCharacteristic(writeCharacteristic, toSend);
      //print("--- send data at this line in code ---");  //<------------------------------ Print to debug
    }
    if ((end - start) % mtuSize != 0) {
      print("in other if");
      int rem = (end - start) % mtuSize;
      Uint8List toSend = Uint8List(rem + 2);
      toSend[0] = 0XFB;
      toSend[1] = parts;
      int variable = 2;
      for (int y = 0; y < rem; y++) {
        int x = data[(position * part) + (mtuSize * parts) + y];
        Uint8List list2 = Uint8List.fromList([x]);

        /// Copy the contents of list1 into the beginning of combinedList
        toSend.setRange(variable, variable + list2.length, list2);
        variable = variable + list2.length;
      }

      /// print statement below should be replaced with actual sending code
      print("2nd write");
      await bleRepo.writeDataCharacteristic(writeCharacteristic, toSend);
    }

    Uint8List update = Uint8List.fromList([
      0xFC,
      ((end - start) ~/ 256),
      ((end - start) % 256),
      (position ~/ 256),
      (position % 256)
    ]);

    /// print statement below should be replaced with actual sending code
    await bleRepo.writeDataCharacteristic(writeCharacteristic, update);
    print("---- send update on this line of code --- $update");
  }

  /// sendPart function ends here

  @override
  Future<void> updateFirmware(
      BluetoothDevice device,
      UpdateType updateType,
      FirmwareType firmwareType,
      {String? uri}
  ) async {
    if (firmwareType != FirmwareType.filepicker && (uri == null || uri.isEmpty)) {
      throw 'uri is required for the specified firmware type.';
    }
    
    // Get MTU size from the device
    int mtuSize = await device.mtu.first;

    if (updateType == UpdateType.espidf) {
      final bleRepo = BleRepository();

      print("MTU size of current device $mtuSize");

      /// Prepare a byte list to write MTU size to controlCharacteristic
      Uint8List byteList = Uint8List(2);
      byteList[0] = mtuSize & 0xFF;
      byteList[1] = (mtuSize >> 8) & 0xFF;

      List<Uint8List> binaryChunks;

      /// Choose firmware source based on firmwareType
      switch (firmwareType) {
        case FirmwareType.assets:
          binaryChunks = await _readBinaryFile(uri!, mtuSize);
          break;
        case FirmwareType.filepicker:
          binaryChunks = await _getFirmwareFromPicker(mtuSize);
          break;
        case FirmwareType.url:
          binaryChunks = await _getFirmwareFromUrl(uri!, mtuSize);
      }

      /// Write x01 to the controlCharacteristic and check if it returns value of 0x02
      await bleRepo.writeDataCharacteristic(writeCharacteristic, byteList);
      await bleRepo.writeDataCharacteristic(
          notifyCharacteristic, Uint8List.fromList([1]));

      /// Read value from controlCharacteristic
      List<int> value = await bleRepo
          .readCharacteristic(notifyCharacteristic)
          .timeout(Duration(seconds: 10));
      print('value returned is this ------- ${value[0]}');

      int packageNumber = 0;
      print('Before Progress');
      for (Uint8List chunk in binaryChunks) {
        /// Write firmware chunks to dataCharacteristic
        await bleRepo.writeDataCharacteristic(writeCharacteristic, chunk);
        packageNumber++;

        double progress = (packageNumber / binaryChunks.length) * 100;
        int roundedProgress = progress.round(); // Rounded off progress value
        print(
            'Writing package number $packageNumber of ${binaryChunks.length} to ESP32');
        print('Progress: $roundedProgress%');
        _percentageController.add(roundedProgress);
      }

      /// Write x04 to the controlCharacteristic to finish the update process
      await bleRepo.writeDataCharacteristic(
          notifyCharacteristic, Uint8List.fromList([4]));

      /// Check if controlCharacteristic reads 0x05, indicating OTA update finished
      value = await bleRepo
          .readCharacteristic(notifyCharacteristic)
          .timeout(Duration(seconds: 600));
      print('value returned is this ------- ${value[0]}');

      if (value[0] == 5) {
        print('OTA update finished');
        firmwareUpdate = true; // Firmware update was successful
      } else {
        print('OTA update failed');
        firmwareUpdate = false; // Firmware update failed
      }
    } else if (updateType == UpdateType.arduino) {

      final bleRepo = BleRepository();

      print("MTU size of current device $mtuSize");

      /// Prepare a byte list to write MTU size to controlCharacteristic
      Uint8List byteList = Uint8List(2);
      byteList[0] = 200 & 0xFF;
      byteList[1] = (200 >> 8) & 0xFF;
      Uint8List? binFile;

      /// Choose firmware source based on firmwareType
      switch (firmwareType) {
        case FirmwareType.assets:
          ByteData fileData = await rootBundle.load(uri!);
          List<int> bytes = fileData.buffer.asUint8List();
          binFile = Uint8List.fromList(bytes);
          print("Bin file after conversion is $binFile");
          print("Bin file length after conversion is ${binFile.length}");
          break;
        case FirmwareType.filepicker:
          binFile = await _getFirmwareFromPickerArduino(200);
          print("binFile is $binFile");
          break;
        case FirmwareType.url:
          binFile = await _getFirmwareFromUrlArduino(uri!, mtuSize);
      }

      print('before printing file Length');
      int fileLen = binFile.length;
      int fileParts = (fileLen / part).ceil();
      print("this is the fileParts :  $fileParts");

      ///1. Start stream which listens to the notification advertisement
      await notifyCharacteristic.setNotifyValue(true);
      subscription = notifyCharacteristic.onValueReceived.listen((value) async {
        print("received value is $value");
        double progress = (value[2] / fileParts) * 100;
        int roundedProgress = progress.round();

        /// Rounded off progress value
        print('Writing part number ${value[2]} of $fileParts to ESP32');
        print('Progress: $roundedProgress%');
        _percentageController.add(roundedProgress);
        if (value[0] == 0xF1)

        /// this basically is checking listener stream
        {
          Uint8List bytes = Uint8List.fromList([
            value[1],
            value[2],
          ]);
          ByteData byteData = ByteData.sublistView(bytes);
          int nxt = byteData.getUint16(0);

          /// Used getUint16 for a 2-byte integer
          print("--------- nxt -------- $nxt");
          sendPart(nxt, binFile!, mtuSize);
        }
        if (value[0] == 0x0F) {
          print("OTA Update complete");
        }
        if (value[0] == 0xF2) {
          print("New bin file installation begins on esp32");
        }
      });

      ///2. Send 0xFD first to start reading
      Uint8List byteListData = Uint8List(1);
      byteList[0] = 0xFD;
      await bleRepo.writeDataCharacteristic(writeCharacteristic, byteListData);

      ///3. Send 0xFE appended with other info
      ///--------> 2nd step create and then send file size
      Uint8List fileSize = Uint8List(5);
      fileSize[0] = 0xFE; // The fixed byte
      fileSize[1] = (fileLen >> 24) & 0xFF; // Most significant byte of fileLen
      fileSize[2] = (fileLen >> 16) & 0xFF; // Second most significant byte
      fileSize[3] = (fileLen >> 8) & 0xFF; // Third most significant byte
      fileSize[4] = fileLen & 0xFF; // Least significant byte
      print(
          "this is file size : $fileSize"); // this is where it is sent to esp32
      await bleRepo.writeDataCharacteristic(writeCharacteristic, fileSize);

      ///4. Send 0xFF appended with other info - see code below
      ///--------> 3rd step create and then send otaInfo
      Uint8List otaInfo = Uint8List(5);
      otaInfo[0] = 0xFF;
      otaInfo[1] = (fileParts ~/ 256);
      otaInfo[2] = (fileParts % 256);
      otaInfo[3] = (mtuSize ~/ 256);
      otaInfo[4] = (mtuSize % 256);
      print("this is otaInfo : $otaInfo"); // this is where it is sent to esp32
      await bleRepo.writeDataCharacteristic(writeCharacteristic, otaInfo);

      ///5. Divide bin file into parts
      int packageNumber = 0;
      sendPart(0, binFile, mtuSize);
      double progress = (packageNumber / fileParts) * 100;
      int roundedProgress = progress.round(); // Rounded off progress value
      print('Writing part number $packageNumber of $fileParts to ESP32');
      print('Progress: $roundedProgress%');
      _percentageController.add(roundedProgress);
    }
  }
}
