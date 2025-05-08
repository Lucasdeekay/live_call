import 'dart:core';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../signaling_service.dart';

// Use a constant for the signaling server URL
const String signalingServerUrl = 'ws://192.168.56.1:8080';

class VideoSize {
  VideoSize(this.width, this.height);

  factory VideoSize.fromString(String size) {
    final parts = size.split('x');
    return VideoSize(int.parse(parts[0]), int.parse(parts[1]));
  }

  final int width;
  final int height;

  @override
  String toString() {
    return '$width x $height';
  }
}

class DeviceEnumerationSample extends StatefulWidget {
  static String tag = 'DeviceEnumerationSample';

  const DeviceEnumerationSample({super.key});

  @override
  _DeviceEnumerationSampleState createState() =>
      _DeviceEnumerationSampleState();
}

class _DeviceEnumerationSampleState extends State<DeviceEnumerationSample> {
  MediaStream? _localStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _inCalling = false;
  bool _isVideoEnabled = true;

  List<MediaDeviceInfo> _devices = [];

  List<MediaDeviceInfo> get audioInputs =>
      _devices.where((device) => device.kind == 'audioinput').toList();

  List<MediaDeviceInfo> get audioOutputs =>
      _devices.where((device) => device.kind == 'audiooutput').toList();

  List<MediaDeviceInfo> get videoInputs =>
      _devices.where((device) => device.kind == 'videoinput').toList();

  String? _selectedVideoInputId;
  String? _selectedAudioInputId;

  String? _selectedVideoFPS = '30';
  VideoSize _selectedVideoSize = VideoSize(1280, 720);

  MediaDeviceInfo get selectedAudioInput => audioInputs.firstWhere(
    (device) => device.deviceId == _selectedVideoInputId,
    orElse: () => audioInputs.first,
  );

  RTCPeerConnection? _peerConnection;
  var senders = <RTCRtpSender>[];

  late SignalingService _signaling;
  var _speakerphoneOn = false;
  var _isOffer = false; // Track if this peer initiated the offer.

  @override
  void initState() {
    super.initState();
    _signaling = SignalingService(
      signalingServerUrl, // Use the constant
      onMessage: _handleSignalingMessage,
    );
    initRenderers();
    loadDevices();
    navigator.mediaDevices.ondevicechange = (event) {
      loadDevices();
    };
  }

  @override
  void deactivate() {
    super.deactivate();
    _stop();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _signaling.dispose();
    navigator.mediaDevices.ondevicechange = null;
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> loadDevices() async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsIOS) {
      var status = await Permission.bluetooth.request();
      if (status.isPermanentlyDenied) print('BLE perm disabled');

      status = await Permission.bluetoothConnect.request();
      if (status.isPermanentlyDenied) print('Connect perm disabled');
    }

    final devices = await navigator.mediaDevices.enumerateDevices();
    setState(() {
      _devices = devices;
    });
  }

  Future<void> _createPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams[0];
      }
      setState(() {});
    };

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        _signaling.send({
          'type': 'candidate',
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      }
    };

    _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      print('ICE connection state changed: $state');
    };
  }

  void _handleSignalingMessage(dynamic message) async {
    final data = jsonDecode(message);
    switch (data['type']) {
      case 'offer':
        if (!_isOffer) {
          print('Received offer...');
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
          final answer = await _peerConnection?.createAnswer();
          await _peerConnection?.setLocalDescription(answer!);
          _signaling.send({'type': 'answer', 'sdp': answer?.sdp});
        }
        break;

      case 'answer':
        print('Received answer...');
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(data['sdp'], data['type']),
        );
        break;

      case 'candidate':
        final candidate = RTCIceCandidate(
          data['candidate']['candidate'],
          data['candidate']['sdpMid'],
          data['candidate']['sdpMLineIndex'],
        );
        await _peerConnection?.addCandidate(candidate);
        break;
      case 'error': //handle errors
        print('Signaling Error: ${data['message']}');
        break;
    }
  }

  Future<void> _start() async {
    try {
      if (await Permission.camera.isDenied ||
          await Permission.microphone.isDenied) {
        await Permission.camera.request();
        await Permission.microphone.request();
      }

      final mediaConstraints = {
        'audio': true, // Keep audio enabled for proper feedback handling
        'video':
            _isVideoEnabled
                ? {
                  if (_selectedVideoInputId != null && kIsWeb)
                    'deviceId': _selectedVideoInputId,
                  if (_selectedVideoInputId != null && !kIsWeb)
                    'optional': [
                      {'sourceId': _selectedVideoInputId},
                    ],
                  'width': _selectedVideoSize.width,
                  'height': _selectedVideoSize.height,
                  'frameRate': int.parse(_selectedVideoFPS!),
                }
                : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      _localRenderer.srcObject = _localStream;

      await _createPeerConnection();

      // Attach tracks.  Important to do this *after* creating the PC.
      if (_localStream != null && _peerConnection != null) {
        for (final track in _localStream!.getTracks()) {
          final sender = await _peerConnection!.addTrack(track, _localStream!);
          senders.add(sender);
        }

        // Initiate the offer if this side starts.
        print('Creating offer...');
        final offer = await _peerConnection!.createOffer();
        await _peerConnection!.setLocalDescription(offer);
        _signaling.send({'type': 'offer', 'sdp': offer.sdp});
        _isOffer = true;
      }

      setState(() {
        _inCalling = true;
      });
    } catch (e) {
      print('Error starting call: $e');
      // Show error to user.
      _showErrorDialog('Failed to start call: $e');
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _stop() async {
    try {
      // Dispose of the stream and renderers.
      await _localStream?.dispose();
      _localStream = null;
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;

      // Close the peer connection.
      await _peerConnection?.close();
      _peerConnection = null;
      senders.clear(); // Clear senders

      setState(() {
        _inCalling = false;
        _speakerphoneOn = false;
        _isOffer = false;
      });
    } catch (e) {
      print('Error stopping call: $e');
      _showErrorDialog('Failed to stop call: $e');
    }
  }

  Future<void> _toggleVideoMode() async {
    _isVideoEnabled = !_isVideoEnabled;

    if (_inCalling) {
      if (_isVideoEnabled) {
        await _selectVideoInput(_selectedVideoInputId);
      } else {
        //stop video track.
        _localStream?.getVideoTracks().forEach((track) async {
          await track.stop();
        });
        _localRenderer.srcObject = null;
      }
    }
    setState(() {});
  }

  Future<void> _selectVideoInput(String? deviceId) async {
    _selectedVideoInputId = deviceId;
    if (!_inCalling || !_isVideoEnabled) return;

    _localRenderer.srcObject = null;

    //stop the existing tracks.
    _localStream?.getTracks().forEach((track) async {
      await track.stop();
    });
    await _localStream?.dispose();

    var newLocalStream = await navigator.mediaDevices.getUserMedia({
      'audio': true, // Keep audio
      'video': {
        if (_selectedVideoInputId != null && kIsWeb)
          'deviceId': _selectedVideoInputId,
        if (_selectedVideoInputId != null && !kIsWeb)
          'optional': [
            {'sourceId': _selectedVideoInputId},
          ],
        'width': _selectedVideoSize.width,
        'height': _selectedVideoSize.height,
        'frameRate': int.parse(_selectedVideoFPS!),
      },
    });

    _localStream = newLocalStream;
    _localRenderer.srcObject = _localStream;

    // Replace the video track.
    var newTrack = _localStream?.getVideoTracks().first;
    var sender = senders.firstWhereOrNull(
      (sender) => sender.track?.kind == 'video',
    );

    if (sender != null) {
      var params = sender.parameters;
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      await sender.setParameters(params);
      await sender.replaceTrack(newTrack);
    }
    setState(() {});
  }

  Future<void> _selectAudioInput(String? deviceId) async {
    _selectedAudioInputId = deviceId;
    if (!_inCalling) return;

    var newLocalStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        if (_selectedAudioInputId != null && kIsWeb)
          'deviceId': _selectedAudioInputId,
        if (_selectedAudioInputId != null && !kIsWeb)
          'optional': [
            {'sourceId': _selectedAudioInputId},
          ],
      },
      'video':
          _isVideoEnabled
              ? {
                'width': _selectedVideoSize.width,
                'height': _selectedVideoSize.height,
                'frameRate': int.parse(_selectedVideoFPS!),
              }
              : false,
    });

    // Replace the audio track.
    var newTrack = newLocalStream.getAudioTracks().first;
    var sender = senders.firstWhereOrNull(
      (sender) => sender.track?.kind == 'audio',
    );
    if (sender != null) {
      await sender.replaceTrack(newTrack);
    }
    //dispose old stream
    _localStream?.getAudioTracks().forEach((track) {
      track.stop();
    });
    await _localStream?.dispose();
    _localStream = newLocalStream;
  }

  Future<void> _selectAudioOutput(String? deviceId) async {
    if (!_inCalling) return;
    await _localRenderer.audioOutput(deviceId!);
  }

  Future<void> _setSpeakerphoneOn() async {
    _speakerphoneOn = !_speakerphoneOn;
    await Helper.setSpeakerphoneOn(_speakerphoneOn);
    setState(() {});
  }

  Future<void> _selectVideoFps(String fps) async {
    _selectedVideoFPS = fps;
    if (!_inCalling) return;
    await _selectVideoInput(_selectedVideoInputId);
  }

  Future<void> _selectVideoSize(String size) async {
    _selectedVideoSize = VideoSize.fromString(size);
    if (!_inCalling) return;
    await _selectVideoInput(_selectedVideoInputId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call Screen'),
        actions: [
          PopupMenuButton<String>(
            onSelected: _selectAudioInput,
            icon: const Icon(Icons.settings_voice),
            itemBuilder: (BuildContext context) {
              return audioInputs
                  .map(
                    (device) => PopupMenuItem<String>(
                      value: device.deviceId,
                      child: Text(device.label),
                    ),
                  )
                  .toList();
            },
          ),
          if (!WebRTC.platformIsMobile)
            PopupMenuButton<String>(
              onSelected: _selectAudioOutput,
              icon: const Icon(Icons.volume_down_alt),
              itemBuilder: (BuildContext context) {
                return audioOutputs
                    .map(
                      (device) => PopupMenuItem<String>(
                        value: device.deviceId,
                        child: Text(device.label),
                      ),
                    )
                    .toList();
              },
            ),
          if (!kIsWeb && WebRTC.platformIsMobile)
            IconButton(
              onPressed: _setSpeakerphoneOn,
              icon: Icon(
                _speakerphoneOn ? Icons.speaker_phone : Icons.phone_android,
              ),
              tooltip: 'Switch SpeakerPhone',
            ),
          PopupMenuButton<String>(
            onSelected: _selectVideoInput,
            icon: const Icon(Icons.switch_camera),
            itemBuilder: (BuildContext context) {
              return videoInputs
                  .map(
                    (device) => PopupMenuItem<String>(
                      value: device.deviceId,
                      child: Text(device.label),
                    ),
                  )
                  .toList();
            },
          ),
          PopupMenuButton<String>(
            onSelected: _selectVideoFps,
            icon: const Icon(Icons.menu),
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: _selectedVideoFPS,
                  child: Text('Select FPS ($_selectedVideoFPS)'),
                ),
                const PopupMenuDivider(),
                ...['8', '15', '30', '60'].map(
                  (fps) => PopupMenuItem<String>(value: fps, child: Text(fps)),
                ),
              ];
            },
          ),
          PopupMenuButton<String>(
            onSelected: _selectVideoSize,
            icon: const Icon(Icons.screenshot_monitor),
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: _selectedVideoSize.toString(),
                  child: Text('Select Video Size ($_selectedVideoSize)'),
                ),
                const PopupMenuDivider(),
                ...['320x180', '640x360', '1280x720', '1920x1080'].map(
                  (size) =>
                      PopupMenuItem<String>(value: size, child: Text(size)),
                ),
              ];
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'toggle_video') {
                _toggleVideoMode();
              }
            },
            icon: const Icon(Icons.videocam),
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: 'toggle_video',
                  child: Text(
                    _isVideoEnabled
                        ? 'Switch to Audio-Only'
                        : 'Switch to Video',
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: OrientationBuilder(
        builder: (context, orientation) {
          return Center(
            child: Container(
              width: MediaQuery.of(context).size.width,
              color: Colors.white10,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: const BoxDecoration(color: Colors.black54),
                      child:
                          _inCalling
                              ? (_isVideoEnabled
                                  ? RTCVideoView(_localRenderer)
                                  : const Center(
                                    child: Icon(
                                      Icons.person,
                                      size: 100,
                                      color: Colors.white,
                                    ),
                                  ))
                              : Container(),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      decoration: const BoxDecoration(color: Colors.black54),
                      child:
                          _inCalling
                              ? (_isVideoEnabled
                                  ? RTCVideoView(_remoteRenderer)
                                  : const Center(
                                    child: Icon(
                                      Icons.person,
                                      size: 100,
                                      color: Colors.white,
                                    ),
                                  ))
                              : Container(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _inCalling ? _stop() : _start();
        },
        tooltip: _inCalling ? 'Hangup' : 'Call',
        child: Icon(_inCalling ? Icons.call_end : Icons.phone),
      ),
    );
  }
}
