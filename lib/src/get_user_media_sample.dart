import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class GetUserMediaSample extends StatefulWidget {
  @override
  _GetUserMediaSampleState createState() => _GetUserMediaSampleState();
}

class _GetUserMediaSampleState extends State<GetUserMediaSample> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  WebSocket? _webSocket;

  bool _inCalling = false;

  final String signalingServerUrl = "ws://192.168.56.1:8080"; // Replace with your WebSocket URL

  @override
  void initState() {
    super.initState();
    initRenderers();
    connectToSignalingServer();
  }

  @override
  void deactivate() {
    super.deactivate();
    if (_inCalling) {
      _hangUp();
    }
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _webSocket?.close();
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> connectToSignalingServer() async {
    _webSocket = await WebSocket.connect(signalingServerUrl);
    _webSocket?.listen(onSignalingMessage, onError: (error) {
      print("WebSocket Error: $error");
    }, onDone: () {
      print("WebSocket connection closed.");
    });
  }

  void onSignalingMessage(dynamic message) async {
    final data = jsonDecode(message);
    switch (data['type']) {
      case 'offer':
        await _handleOffer(data['sdp']);
        break;
      case 'answer':
        await _handleAnswer(data['sdp']);
        break;
      case 'candidate':
        await _handleCandidate(data['candidate']);
        break;
    }
  }

  Future<void> _makeCall() async {
    final config = {
      "iceServers": [
        {"urls": "stun:stun.l.google.com:19302"}
      ]
    };
    final constraints = {
      'mandatory': {},
      'optional': [],
    };

    _peerConnection = await createPeerConnection(config, constraints);

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      _sendMessage({
        'type': 'candidate',
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
        });
      }
    };

    final mediaConstraints = {
      'audio': true,
      'video': {
        'facingMode': 'user',
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    _localStream?.getTracks().forEach((track) {
      _peerConnection?.addTrack(track, _localStream!);
    });

    _localRenderer.srcObject = _localStream;

    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    _sendMessage({
      'type': 'offer',
      'sdp': offer.sdp,
    });

    setState(() {
      _inCalling = true;
    });
  }

  Future<void> _handleOffer(String sdp) async {
    if (_peerConnection == null) {
      await _makeCall();
    }
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    _sendMessage({
      'type': 'answer',
      'sdp': answer.sdp,
    });
  }

  Future<void> _handleAnswer(String sdp) async {
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
  }

  Future<void> _handleCandidate(Map<String, dynamic> candidateData) async {
    final candidate = RTCIceCandidate(
      candidateData['candidate'],
      candidateData['sdpMid'],
      candidateData['sdpMLineIndex'],
    );
    await _peerConnection?.addCandidate(candidate);
  }

  Future<void> _hangUp() async {
    _localStream?.getTracks().forEach((track) => track.stop());
    await _peerConnection?.close();
    _peerConnection = null;

    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;

    setState(() {
      _inCalling = false;
    });

    _sendMessage({'type': 'hangup'});
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_webSocket != null) {
      _webSocket!.add(jsonEncode(message));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebRTC with WebSocket'),
      ),
      body: Column(
        children: [
          Expanded(
            child: RTCVideoView(_localRenderer, mirror: true),
          ),
          Expanded(
            child: RTCVideoView(_remoteRenderer),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _inCalling ? _hangUp : _makeCall,
        tooltip: _inCalling ? 'Hang Up' : 'Call',
        child: Icon(_inCalling ? Icons.call_end : Icons.phone),
      ),
    );
  }
}
