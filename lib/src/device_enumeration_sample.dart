import 'dart:core';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingService {
  final WebSocketChannel _channel;
  final Function(dynamic) onMessage;

  SignalingService(String url, {required this.onMessage})
    : _channel = WebSocketChannel.connect(Uri.parse(url)) {
    _channel.stream.listen(onMessage);
  }

  void send(dynamic message) {
    _channel.sink.add(jsonEncode(message));
  }

  void dispose() {
    _channel.sink.close();
  }
}

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
  var _isOffer = false;

  @override
  void initState() {
    super.initState();
    _signaling = SignalingService(
      'ws://192.168.56.1:8080',
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

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        _remoteRenderer.srcObject = event.streams[0];
      }
      setState(() {});
    };
  }

  void _handleSignalingMessage(dynamic message) async {
    final data = jsonDecode(message);
    switch (data['type']) {
      case 'offer':
        if (!_isOffer) {
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
          final answer = await _peerConnection?.createAnswer();
          await _peerConnection?.setLocalDescription(answer!);
          _signaling.send({'type': 'answer', 'sdp': answer?.sdp});
        }
        break;

      case 'answer':
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
        'audio': true,
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
                  'frameRate': _selectedVideoFPS,
                }
                : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      _localRenderer.srcObject = _localStream;

      await _createPeerConnection();

      // Properly handle track addition with null checks
      if (_localStream != null && _peerConnection != null) {
        for (final track in _localStream!.getTracks()) {
          final sender = await _peerConnection!.addTrack(track, _localStream!);
          senders.add(sender);
        }
      }

      if (_isOffer) {
        final offer = await _peerConnection?.createOffer();
        await _peerConnection?.setLocalDescription(offer!);
        _signaling.send({'type': 'offer', 'sdp': offer?.sdp});
      }

      setState(() {
        _inCalling = true;
      });
    } catch (e) {
      print('Error starting call: $e');
    }
  }

  Future<void> _stop() async {
    try {
      await _localStream?.dispose();
      _localStream = null;
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;

      await _peerConnection?.close();
      _peerConnection = null;

      setState(() {
        _inCalling = false;
        _speakerphoneOn = false;
      });
    } catch (e) {
      print('Error stopping call: $e');
    }
  }

  // ... (keep all other methods like _toggleVideoMode, _selectVideoInput, etc. the same)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebRTC Call'),
        actions: [
          IconButton(
            icon: Icon(_isOffer ? Icons.call : Icons.call_received),
            onPressed: () {
              setState(() {
                _isOffer = !_isOffer;
              });
            },
            tooltip: _isOffer ? 'Switch to Answer' : 'Switch to Offer',
          ),
          // ... (keep all other action buttons the same)
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
                                  : Center(
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
                                  : Center(
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
