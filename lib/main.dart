import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart'; 
import 'dart:html' as html; 

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
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  XFile? _selectedImage;
  Uint8List? _processedImageBytes;
  
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;
  String _loadingText = '';

  final TextEditingController _colsController = TextEditingController(text: '2');
  final TextEditingController _rowsController = TextEditingController(text: '2');

  List<double> _vLines = [0.5];
  List<double> _hLines = [0.5];

  @override
  void initState() {
    super.initState();
    _colsController.addListener(_resetGridLines);
    _rowsController.addListener(_resetGridLines);
  }

  @override
  void dispose() {
    _colsController.dispose();
    _rowsController.dispose();
    super.dispose();
  }

  void _resetGridLines() {
    int cols = int.tryParse(_colsController.text) ?? 1;
    int rows = int.tryParse(_rowsController.text) ?? 1;
    cols = cols.clamp(1, 10);
    rows = rows.clamp(1, 10);

    setState(() {
      _vLines = List.generate(cols - 1, (i) => (i + 1) / cols);
      _hLines = List.generate(rows - 1, (i) => (i + 1) / rows);
    });
  }

  // 1. 挑選圖片
  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _selectedImage = image;
        _processedImageBytes = null; // 換新圖片時清空去背結果
      });
    }
  }

  // 2. 智慧去背 (連線 Python 伺服器)
  Future<void> _removeBackground() async {
    if (_selectedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請先挑選一張照片喔！')));
      return;
    }

    setState(() {
      _isProcessing = true;
      _loadingText = 'AI 正在努力去背中...';
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      var request = http.MultipartRequest('POST', Uri.parse('http://10.1.152.25:8000/remove-bg/'));
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'upload.png'));
      
      var response = await request.send();
      
      if (response.statusCode == 200) {
        final responseBytes = await response.stream.toBytes();
        setState(() {
          _processedImageBytes = responseBytes;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✨ 去背成功！')));
      } else {
        throw Exception('伺服器回傳錯誤代碼: ${response.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('連線失敗，請確認 Python 伺服器有啟動！錯誤: $e')));
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // 3. 分割圖片與雙軌下載邏輯
  Future<void> _splitImage() async {
    if (_selectedImage == null) return;

    setState(() {
      _isProcessing = true;
      _loadingText = '正在運算切割...';
    });

    try {
      final bytes = _processedImageBytes ?? await _selectedImage!.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) throw Exception('圖片讀取失敗');

      List<Uint8List> splitImages = [];
      List<double> xPoints = [0.0, ..._vLines, 1.0];
      List<double> yPoints = [0.0, ..._hLines, 1.0];

      final archive = Archive(); // 準備 ZIP 壓縮檔

      // 執行切割
      for (int y = 0; y < yPoints.length - 1; y++) {
        for (int x = 0; x < xPoints.length - 1; x++) {
          int startX = (xPoints[x] * image.width).toInt();
          int endX = (xPoints[x + 1] * image.width).toInt();
          int startY = (yPoints[y] * image.height).toInt();
          int endY = (yPoints[y + 1] * image.height).toInt();

          img.Image cropped = img.copyCrop(
            image,
            x: startX,
            y: startY,
            width: endX - startX,
            height: endY - startY,
          );
          
          final pngBytes = Uint8List.fromList(img.encodePng(cropped));
          splitImages.add(pngBytes);
          
          // 將檔案加入 ZIP
          final filename = 'sticker_${(splitImages.length).toString().padLeft(2, '0')}.png';
          archive.addFile(ArchiveFile(filename, pngBytes.length, pngBytes));
        }
      }

      setState(() => _isProcessing = false);

      // 彈出預覽與下載視窗
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('🎉 成功分割為 ${splitImages.length} 份'),
            backgroundColor: Colors.grey[800],
            titleTextStyle: const TextStyle(color: Colors.white, fontSize: 18),
            content: SizedBox(
              width: 300,
              height: 300,
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: splitImages.map((b) => Image.memory(b, width: 80, fit: BoxFit.contain)).toList(),
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center, // 讓按鈕置中排列
            actions: [
              // 雙下載選項之一：逐一下載 PNG
              ElevatedButton.icon(
                onPressed: () {
                  if (kIsWeb) {
                    for (int i = 0; i < splitImages.length; i++) {
                      final blob = html.Blob([splitImages[i]]);
                      final url = html.Url.createObjectUrlFromBlob(blob);
                      final filename = 'sticker_${(i + 1).toString().padLeft(2, '0')}.png';
                      html.AnchorElement(href: url)
                        ..setAttribute("download", filename)
                        ..click();
                      html.Url.revokeObjectUrl(url);
                    }
                  }
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('✅ 已觸發連續下載，若瀏覽器阻擋請點選「允許」！'))
                  );
                },
                icon: const Icon(Icons.collections),
                label: const Text('逐張下載 (PNG)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlueAccent,
                  foregroundColor: Colors.black,
                ),
              ),
              
              // 雙下載選項之二：打包下載 ZIP
              ElevatedButton.icon(
                onPressed: () {
                  if (kIsWeb) {
                    final zipBytes = ZipEncoder().encode(archive);
                    if (zipBytes != null) {
                      final blob = html.Blob([zipBytes]);
                      final url = html.Url.createObjectUrlFromBlob(blob);
                      final anchor = html.AnchorElement(href: url)
                        ..setAttribute("download", "my_stickers.zip")
                        ..click();
                      html.Url.revokeObjectUrl(url);
                    }
                  }
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('✅ 壓縮檔已下載！'))
                  );
                },
                icon: const Icon(Icons.folder_zip),
                label: const Text('打包下載 (ZIP)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                ),
              ),

              // 關閉按鈕
              TextButton(
                onPressed: () => Navigator.pop(context), 
                child: const Text('關閉', style: TextStyle(color: Colors.grey))
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('發生錯誤：$e')));
    }
  }

  // --- 互動式網格 ---
  Widget _buildInteractiveGrid() {
    if (_selectedImage == null && _processedImageBytes == null) {
      return Container(width: double.infinity, height: 250, decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(15)), child: const Icon(Icons.image, size: 80, color: Colors.grey));
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 350),
      child: Stack(
        alignment: Alignment.center,
        children: [
          _processedImageBytes != null
              ? Image.memory(_processedImageBytes!, fit: BoxFit.contain)
              : (kIsWeb ? Image.network(_selectedImage!.path, fit: BoxFit.contain) : Image.file(File(_selectedImage!.path), fit: BoxFit.contain)),
          
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double w = constraints.maxWidth;
                final double h = constraints.maxHeight;

                return Stack(
                  children: [
                    ..._vLines.asMap().entries.map((e) {
                      int index = e.key; double percent = e.value;
                      return Positioned(
                        left: percent * w - 15, top: 0, bottom: 0, width: 30,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              double newPercent = _vLines[index] + details.delta.dx / w;
                              double minLimit = index == 0 ? 0.02 : _vLines[index - 1] + 0.05;
                              double maxLimit = index == _vLines.length - 1 ? 0.98 : _vLines[index + 1] - 0.05;
                              _vLines[index] = newPercent.clamp(minLimit, maxLimit);
                            });
                          },
                          child: Center(child: Container(width: 3, color: Colors.redAccent.withOpacity(0.8))),
                        ),
                      );
                    }),
                    ..._hLines.asMap().entries.map((e) {
                      int index = e.key; double percent = e.value;
                      return Positioned(
                        top: percent * h - 15, left: 0, right: 0, height: 30,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: (details) {
                            setState(() {
                              double newPercent = _hLines[index] + details.delta.dy / h;
                              double minLimit = index == 0 ? 0.02 : _hLines[index - 1] + 0.05;
                              double maxLimit = index == _hLines.length - 1 ? 0.98 : _hLines[index + 1] - 0.05;
                              _hLines[index] = newPercent.clamp(minLimit, maxLimit);
                            });
                          },
                          child: Center(child: Container(height: 3, color: Colors.blueAccent.withOpacity(0.8))),
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('貼圖去背與分割工具', style: TextStyle(color: Colors.white)), backgroundColor: Colors.teal),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              Container(
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage('https://upload.wikimedia.org/wikipedia/commons/5/5c/Image_checkerboard.png'),
                    repeat: ImageRepeat.repeat,
                  ),
                ),
                child: _buildInteractiveGrid(),
              ),
              const SizedBox(height: 30),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(child: TextField(controller: _colsController, decoration: const InputDecoration(labelText: '縱向分割線 (切出直欄)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.view_column)), keyboardType: TextInputType.number, textAlign: TextAlign.center)),
                    const SizedBox(width: 15),
                    Expanded(child: TextField(controller: _rowsController, decoration: const InputDecoration(labelText: '橫向分割線 (切出橫列)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.table_rows)), keyboardType: TextInputType.number, textAlign: TextAlign.center)),
                  ],
                ),
              ),
              const SizedBox(height: 30),

              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _pickImage,
                icon: const Icon(Icons.add_photo_alternate), label: const Text('1. 從相簿選擇圖片'), style: ElevatedButton.styleFrom(minimumSize: const Size(250, 45))),
              const SizedBox(height: 15),
              
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _removeBackground,
                icon: _isProcessing && _loadingText.contains('AI')
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_fix_high),
                label: Text(_isProcessing && _loadingText.contains('AI') ? _loadingText : '2. 一鍵智慧去背'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(250, 45))),
              const SizedBox(height: 15),
              
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _splitImage,
                icon: _isProcessing && _loadingText.contains('切割')
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.grid_on),
                label: Text(_isProcessing && _loadingText.contains('切割') ? _loadingText : '3. 分割圖片 (雙軌下載)'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(250, 45))),
            ],
          ),
        ),
      ),
    );
  }
}