import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';

// ----------------------------------------------------------------------
// 1) Node.js SERVER URL:
//    - For real devices on the same Wi-Fi, use your computer's LAN IP (e.g., "http://192.168.182.41:5000").
//    - For an Android Emulator, use "http://10.0.2.2:5000".
// ----------------------------------------------------------------------
const String tokenServerBaseUrl = "http://192.168.182.41:5000";

// ----------------------------------------------------------------------
// 2) AGORA APP ID:
//    Must exactly match the AGORA_APP_ID in your server's .env file.
// ----------------------------------------------------------------------
const String agoraAppId = "cf8cc3c35a9a48a1a09d51df0bcca626";

void main() {
  runApp(const AgoraApp());
}

class AgoraApp extends StatelessWidget {
  const AgoraApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agora Video Call',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: Colors.grey[200],
      ),
      home: const HomePage(),
    );
  }
}

// HomePage: User enters channel name and UID.
class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _channelController = TextEditingController();
  final _uidController = TextEditingController();

  void _joinCall() {
    final channel = _channelController.text.trim();
    final uidString = _uidController.text.trim();

    if (channel.isEmpty || uidString.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter channel name and UID")),
      );
      return;
    }

    final uid = int.tryParse(uidString) ?? 0;
    if (uid <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("UID must be an integer > 0")),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallPage(channelName: channel, uid: uid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agora Video Call'),
      ),
      body: Center(
        child: Card(
          elevation: 4,
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Enter Channel & UID',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _channelController,
                  decoration: const InputDecoration(
                    labelText: 'Channel Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _uidController,
                  decoration: const InputDecoration(
                    labelText: 'UID (integer)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _joinCall,
                  icon: const Icon(Icons.video_call),
                  label: const Text("Join Call"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// CallPage: Fetch token, join channel, and display local and remote video.
class CallPage extends StatefulWidget {
  final String channelName;
  final int uid;
  const CallPage({
    Key? key,
    required this.channelName,
    required this.uid,
  }) : super(key: key);

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late RtcEngine _engine;
  bool _isJoined = false;
  int _remoteUid = 0;

  @override
  void initState() {
    super.initState();
    _initAgora();
  }

  Future<void> _initAgora() async {
    // Request camera and microphone permissions.
    await [Permission.camera, Permission.microphone].request();

    // Create and initialize the Agora engine.
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(appId: agoraAppId));

    // Set the client role to broadcaster using the new API.
    await _engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

    // Register event handlers.
    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        setState(() {
          _isJoined = true;
        });
        debugPrint("Local user joined channel: ${connection.localUid}");
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        setState(() {
          _remoteUid = remoteUid;
        });
        debugPrint("Remote user $remoteUid joined");
      },
      onUserOffline: (connection, remoteUid, reason) {
        setState(() {
          _remoteUid = 0;
        });
        debugPrint("Remote user $remoteUid left channel");
      },
    ));

    // Join the channel.
    await _joinChannel();
  }

  Future<void> _joinChannel() async {
    try {
      // Request token from your Node.js server.
      final url = Uri.parse("$tokenServerBaseUrl/agora/token");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "channelName": widget.channelName,
          "uid": widget.uid,
        }),
      );
      if (response.statusCode != 200) {
        throw "Token server error: ${response.body}";
      }
      final data = jsonDecode(response.body);
      final token = data["token"];
      if (token == null) throw "Token not found in server response";

      debugPrint("Got token: $token");

      // Enable video and start the preview.
      await _engine.enableVideo();
      await _engine.startPreview();

      // Join the channel with the token.
      await _engine.joinChannel(
        token: token,
        channelId: widget.channelName,
        uid: widget.uid,
        options: const ChannelMediaOptions(),
      );
    } catch (e) {
      debugPrint("joinChannel error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Join channel failed: $e")),
      );
    }
  }

  Future<void> _leaveChannel() async {
    await _engine.leaveChannel();
    setState(() {
      _isJoined = false;
      _remoteUid = 0;
    });
    Navigator.of(context).pop();
  }

  // Render the local video preview.
  Widget _renderLocalPreview() {
    if (!_isJoined) {
      return const Center(child: Text("Joining..."));
    }
    return AgoraVideoView(
      controller: VideoViewController(
        rtcEngine: _engine,
        canvas: const VideoCanvas(uid: 0),
      ),
    );
  }

  // Render the remote video view.
  Widget _renderRemoteVideo() {
    if (_remoteUid == 0) {
      return const Center(child: Text("Waiting for remote user..."));
    }
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _engine,
        canvas: VideoCanvas(uid: _remoteUid),
        connection: RtcConnection(channelId: widget.channelName),
      ),
    );
  }

  @override
  void dispose() {
    _engine.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Channel: ${widget.channelName}"),
        actions: [
          IconButton(
            onPressed: _leaveChannel,
            icon: const Icon(Icons.exit_to_app),
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _renderLocalPreview()),
          const Divider(height: 2),
          Expanded(child: _renderRemoteVideo()),
        ],
      ),
    );
  }
}
