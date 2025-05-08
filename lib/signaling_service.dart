import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingService {
  final WebSocketChannel _channel;

  SignalingService(String url)
      : _channel = WebSocketChannel.connect(Uri.parse(url));

  void send(String message) {
    _channel.sink.add(message);
  }

  Stream<String> get messages => _channel.stream.cast<String>();

  void dispose() {
    _channel.sink.close();
  }
}
