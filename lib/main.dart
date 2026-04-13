import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'dart:html' as html;
import 'package:archive/archive.dart';

void main() {
  runApp(const StickerMakerApp());
}

class StickerMakerApp extends StatelessWidget {
  const StickerMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '貼圖製作神器',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  Uint8List? _processedImageBytes;
  List<Uint8List> _splitImagesBytes = [];
  
  bool _isProcessing = false;
  String _loadingText = '';
  
  int _rows = 4;
  int _cols = 4;

  // 1. 選擇圖片
  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _selectedImage = image;
        _processedImageBytes = null;
        _splitImagesBytes = [];
      });
    }
  }

  // 2. 呼叫 Python 雲端大腦去背
  Future<void> _removeBackground() async {
    if (_selectedImage == null) return;

    setState(() {
      _isProcessing = true;
      _loadingText = 'AI 正在努力去背中... (首次喚醒約需 30-50 秒)';
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      
      // 💡 確保網址結尾有斜線 '/'
      var request = http.MultipartRequest(
        'POST', 
        Uri.parse('https://sticker-maker-for-rebecca.onrender.com/remove-bg/')
      );
      
      // 💡 針對 iPhone Safari 的救星：明確指定 Headers
      request.headers['Accept'] = '*/*';
      request.headers['User-Agent'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1';

      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'upload.png'));

      var response = await request.send();

      if (response.statusCode == 200) {
        final responseBytes = await response.stream.toBytes();
        setState(() {
          _processedImageBytes = responseBytes;
          _splitImagesBytes = []; // 清空之前的分割
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✨ 去背成功！')));
        }
      } else {
        throw Exception('伺服器錯誤代碼: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('連線失敗，請再試一次或檢查網路！錯誤: $e'),
          duration: const Duration(seconds: 5),
        ));
      }
    } finally {
      setState(() {
        _isProcessing = false;
        _loadingText = '';
      });
    }
  }

  // 3. 分割圖片
  Future<void> _splitImage() async {
    if (_processedImageBytes == null) return;

    setState(() {
      _isProcessing = true;
      _loadingText = '正在分割圖片...';
    });

    // 使用 compute 或 Future.delayed 避免畫面卡住
    await Future.delayed(const Duration(milliseconds: 100)); 

    try {
      img.Image? originalImage = img.decodeImage(_processedImageBytes!);
      if (originalImage == null) throw Exception("無法解析圖片");

      int pieceWidth = originalImage.width ~/ _cols;
      int pieceHeight = originalImage.height ~/ _rows;
      List<Uint8List> tempSplit = [];

      for (int y = 0; y < _rows; y++) {
        for (int x = 0; x < _cols; x++) {
          img.Image cropped = img.copyCrop(
            originalImage,
            x: x * pieceWidth,
            y: y * pieceHeight,
            width: pieceWidth,
            height: pieceHeight,
          );
          tempSplit.add(Uint8List.fromList(img.encodePng(cropped)));
        }
      }

      setState(() {
        _splitImagesBytes = tempSplit;
      });
      
      // 分割完成後直接觸發打包下載
      _downloadAllAsZip();

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分割失敗: $e')));
      }
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  // 4. 將分割後的圖片打包成 ZIP 並下載 (解決 iPhone 限制)
  void _downloadAllAsZip() {
    if (_splitImagesBytes.isEmpty) return;

    final archive = Archive();

    for (int i = 0; i < _splitImagesBytes.length; i++) {
      final imageBytes = _splitImagesBytes[i];
      final fileName = 'sticker_${i + 1}.png';
      final archiveFile = ArchiveFile(fileName, imageBytes.length, imageBytes);
      archive.addFile(archiveFile);
    }

    final zipData = ZipEncoder().encode(archive);

    if (zipData != null) {
      final blob = html.Blob([zipData]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute("download", "Alishan_Stickers.zip") // 下載的檔名
        ..click();
      html.Url.revokeObjectUrl(url);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('📦 已打包下載為 ZIP 檔案！')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('貼圖去背與分割工具', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.teal,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // --- 圖片預覽區 ---
            Container(
              height: 350,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                border: Border.all(color: Colors.teal, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _splitImagesBytes.isNotEmpty
                  ? GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _cols,
                        crossAxisSpacing: 2,
                        mainAxisSpacing: 2,
                      ),
                      itemCount: _splitImagesBytes.length,
                      itemBuilder: (context, index) {
                        return Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                          ),
                          child: Image.memory(_splitImagesBytes[index], fit: BoxFit.contain),
                        );
                      },
                    )
                  : _processedImageBytes != null
                      ? Image.memory(_processedImageBytes!, fit: BoxFit.contain)
                      : _selectedImage != null
                          ? Image.network(_selectedImage!.path, fit: BoxFit.contain)
                          : const Center(child: Text('尚未選擇圖片', style: TextStyle(color: Colors.grey))),
            ),
            const SizedBox(height: 20),

            // --- 切割行列設定區 ---
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: '縱向分割線 (切出幾列)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.view_stream)),
                    keyboardType: TextInputType.number,
                    onChanged: (value) => setState(() => _rows = int.tryParse(value) ?? 4),
                    controller: TextEditingController(text: _rows.toString()),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: '橫向分割線 (切出幾行)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.view_column)),
                    keyboardType: TextInputType.number,
                    onChanged: (value) => setState(() => _cols = int.tryParse(value) ?? 4),
                    controller: TextEditingController(text: _cols.toString()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),

            // --- 按鈕控制區 ---
            if (_isProcessing)
              Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(_loadingText, style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                ],
              )
            else ...[
              ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library),
                label: const Text('1. 從相簿選擇圖片'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
              ),
              const SizedBox(height: 15),
              ElevatedButton.icon(
                onPressed: _selectedImage != null ? _removeBackground : null,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('2. 一鍵智慧去背'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 15),
              ElevatedButton.icon(
                onPressed: _processedImageBytes != null ? _splitImage : null,
                icon: const Icon(Icons.grid_on),
                label: const Text('3. 分割圖片並打包下載 (ZIP)'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
