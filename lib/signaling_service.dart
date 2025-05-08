import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';


class SignalingService {
  final String _serverUrl;
  final void Function(dynamic) _onMessage;
  WebSocketChannel? _channel;

  SignalingService(this._serverUrl, {required void Function(dynamic) onMessage})
    : _onMessage = onMessage {
    _connect();
  }

  void _connect() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      _channel?.stream.listen(
        (message) {
          _onMessage(message);
        },
        onError: (error) {
          print('WebSocket error: $error');
          // Consider reconnecting here.
        },
        onDone: () {
          print('WebSocket connection closed');
          // Consider reconnecting here.
        },
      );
    } catch (e) {
      print('Error connecting to signaling server: $e');
    }
  }

  void send(dynamic message) {
    if (_channel?.sink != null) {
      _channel?.sink.add(jsonEncode(message));
    } else {
      print('Not connected to signaling server.');
      // Handle the case where the connection is not available.
      _connect(); //try to reconnect.
    }
  }

  void dispose() {
    _channel?.sink.close();
  }
}
