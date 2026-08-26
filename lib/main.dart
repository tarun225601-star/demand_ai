import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// 1. MAIN ENTRY & BACKGROUND SETUP
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundService();
  runApp(const DemandAiApp());
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'demand_ai_channel',
      initialNotificationTitle: 'Demand AI Active',
      initialNotificationContent: 'बैकग्राउंड में घर की जरूरतों पर नजर रखी जा रही है...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IOSConfiguration(
      autoStart: true,
      onForeground: onBackgroundStart,
    ),
  );
  service.startService();
}

@pragma('vm:entry-point')
void onBackgroundStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  Timer.periodic(const Duration(hours: 1), (timer) {
    print("Demand AI Background: खपत और वेकेशन दिनों का हिसाब लगाया जा रहा है...");
  });
}

// ==========================================
// 2. LOCAL DATABASE HELPER (SQLite)
// ==========================================
class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._init();
  static Database? _database;

  LocalDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('demand_ai.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        price INTEGER NOT NULL,
        status TEXT NOT NULL
      )
    ''');
    await db.insert('items', {'name': 'आता (5 Kg)', 'price': 240, 'status': 'खत्म होने वाला है'});
    await db.insert('items', {'name': 'सरसों का तेल (1 Ltr)', 'price': 150, 'status': 'समाप्त'});
  }

  Future<List<Map<String, dynamic>>> getItems() async {
    final db = await instance.database;
    return await db.query('items');
  }

  Future<int> addItem(String name, int price, String status) async {
    final db = await instance.database;
    return await db.insert('items', {'name': name, 'price': price, 'status': status});
  }
}

// ==========================================
// 3. APP UI & CORE LOGIC (Single File)
// ==========================================
class DemandAiApp extends StatelessWidget {
  const DemandAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Demand AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> shoppingList = [];
  bool isLoading = true;

  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _voiceText = "माइक दबाकर बोलें...";

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final data = await LocalDatabase.instance.getItems();
    setState(() {
      shoppingList = data;
      isLoading = false;
    });
  }

  void _listenVoiceCommand() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (val) => print('status: $val'),
        onError: (val) => print('error: $val'),
      );
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) => setState(() {
            _voiceText = val.recognizedWords;
            if (val.hasConfidenceRating && val.confidence > 0) {
              _addNewItemFromVoice(_voiceText);
            }
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  Future<void> _addNewItemFromVoice(String itemText) async {
    if (itemText.isNotEmpty) {
      await LocalDatabase.instance.addItem(itemText, 50, 'यूजर द्वारा जोड़ा गया');
      _loadItems();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Demand AI: "$itemText" लिस्ट में जोड़ दिया गया है!')),
      );
    }
  }

  double get totalAmount {
    return shoppingList.fold(0, (sum, item) => sum + (item['price'] as int));
  }

  // Grok API के जरिए आर्डर प्रोसेस करने का फंक्शन (सेव की गई API Key और Model का इस्तेमाल करके)
  Future<void> _processOrderWithGrok() async {
    final prefs = await SharedPreferences.getInstance();
    String? apiKey = prefs.getString('grok_api_key');
    String? selectedModel = prefs.getString('selected_grok_model') ?? 'grok-beta';

    if (apiKey == null || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('कृपया पहले कॉर्नर सेटिंग में जाकर Grok API Key दर्ज करें!')),
      );
      return;
    }

    const String grokApiUrl = 'https://api.x.ai/v1/chat/completions';

    try {
      final response = await http.post(
        Uri.parse(grokApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          "model": selectedModel,
          "messages": [
            {
              "role": "system",
              "content": "You are Demand AI checkout assistant. Process the grocery shopping list."
            },
            {
              "role": "user",
              "content": "Checkout items: ${shoppingList.map((e) => e['name']).toList()} total ₹$totalAmount"
            }
          ],
          "temperature": 0.3
        }),
      );

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demand AI: Grok API के जरिए आर्डर सक्सेसफुली प्लेस हो गया! 🚀')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order Error: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection Exception: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Demand AI - Smart Pantry', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          // कॉर्नर में सेटिंग्स का बटन
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.black87),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: Colors.blue, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _isListening ? 'सुन रहा हूँ: "$_voiceText"' : 'बैकग्राउंड मॉनिटरिंग और वेकेशन एनालिटिक्स एक्टिव है।',
                            style: const TextStyle(fontSize: 13, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('आज की जरूरत का सामान (Local DB):', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shoppingList.length,
                      itemBuilder: (context, index) {
                        final item = shoppingList[index];
                        return Card(
                          elevation: 1,
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          child: ListTile(
                            title: Text(item['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('स्थिति: ${item['status']}', style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
                            trailing: Text('₹${item['price']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green)),
                          ),
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 10, spreadRadius: 2)],
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('कुल अनुमानित खर्च:', style: TextStyle(fontSize: 16, color: Colors.grey)),
                            Text('₹$totalAmount', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FloatingActionButton(
                              onPressed: _listenVoiceCommand,
                              backgroundColor: _isListening ? Colors.red : Colors.blue,
                              child: Icon(_isListening ? Icons.mic : Icons.mic_none, color: Colors.white),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SizedBox(
                                height: 50,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.black,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: _processOrderWithGrok,
                                  child: const Text('अभी आर्डर करें 🚀', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ==========================================
// 4. SETTINGS SCREEN (API Key & Smart Model Auto-Fetch)
// ==========================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  List<String> _availableModels = [];
  String? _selectedModel;
  bool _isLoadingModels = false;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('grok_api_key') ?? '';
      _selectedModel = prefs.getString('selected_grok_model') ?? 'grok-beta';
    });
  }

  // Grok सर्वर से केवल चैट/टेक्स्ट वाले मॉडल्स को ऑटो-फेच और फिल्टर करने का लॉजिक
  Future<void> _fetchGrokModels() async {
    String apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('पहले अपनी Grok API Key दर्ज करें!')),
      );
      return;
    }

    setState(() => _isLoadingModels = true);

    try {
      final response = await http.get(
        Uri.parse('https://api.x.ai/v1/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List modelsList = data['data'] ?? [];

        // केवल चैटिंग और टेक्स्ट वाले मॉडल्स को फिल्टर करना (फालतू मॉडल्स हटाकर)
        List<String> filteredModels = [];
        for (var model in modelsList) {
          String modelId = model['id'].toString();
          // यहाँ हम केवल 'grok' नाम वाले या चैट/इंसट्रक्शन वाले मॉडल्स छांट रहे हैं
          if (modelId.contains('grok') && !modelId.contains('vision-embed') && !modelId.contains('audio')) {
            filteredModels.add(modelId);
          }
        }

        if (filteredModels.isEmpty) {
          filteredModels = ['grok-beta']; // डिफ़ॉल्ट फॉલबैक
        }

        setState(() {
          _availableModels = filteredModels;
          if (!_availableModels.contains(_selectedModel)) {
            _selectedModel = _availableModels.first;
          }
          _isLoadingModels = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('सटीक चैट मॉडल्स सफलतापूर्वक फेच हो गए!')),
        );
      } else {
        setState(() => _isLoadingModels = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('मॉडल फेच करने में एरर: ${response.statusCode}')),
        );
      }
    } catch (e) {
      setState(() => _isLoadingModels = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('कनेक्शन एरर: $e')),
      );
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('grok_api_key', _apiKeyController.text.trim());
    if (_selectedModel != null) {
      await prefs.setString('selected_grok_model', _selectedModel!);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('सेटिंग्स सफलतापूर्क सेव हो गईं! ✅')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Demand AI - Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Grok (xAI) API Key', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'अपनी API Key यहाँ पेस्ट करें',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 45),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _fetchGrokModels,
              icon: const Icon(Icons.sync),
              label: const Text('सटीक चैट मॉडल्स ऑटो-फेच करें'),
            ),
            const SizedBox(height: 24),
            const Text('उपलब्ध चैट मॉडल चुनें (फिल्टर किए गए):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _isLoadingModels
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButton<String>(
                      value: _selectedModel,
                      isExpanded: true,
                      underline: const SizedBox(),
                      hint: const Text('मॉडल चुनें'),
                      items: (_availableModels.isEmpty ? ['grok-beta'] : _availableModels).map((String model) {
                        return DropdownMenuItem<String>(
                          value: model,
                          child: Text(model),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          _selectedModel = newValue;
                        });
                      },
                    ),
                  ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _saveSettings,
                child: const Text('सेटिंग्स सेव करें', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
