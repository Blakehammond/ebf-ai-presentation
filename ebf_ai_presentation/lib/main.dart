import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:audioplayers/audioplayers.dart';

void main() {
  runApp(const EBFAIPresentation());
}

// Define custom brand colors
const Color kFuchsia = Color(0xFFD946EF);
const Color kFuchsiaAccent = Color(0xFFF0ABFC);
const Color kCyanAccent = Color(0xFF22D3EE);
const Color kDeepSlate = Color(0xFF0F172A);

class EBFAIPresentation extends StatelessWidget {
  const EBFAIPresentation({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EBF AI Experience',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kFuchsia,
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.spaceGroteskTextTheme(ThemeData.dark().textTheme),
      ),
      home: const PresentationRouter(),
    );
  }
}

class PresentationRouter extends StatefulWidget {
  const PresentationRouter({super.key});

  @override
  State<PresentationRouter> createState() => _PresentationRouterState();
}

class _PresentationRouterState extends State<PresentationRouter> {
  bool _isPresenter = false;

  @override
  void initState() {
    super.initState();
    _checkMode();
    web.window.addEventListener('hashchange', (web.Event event) {
      _checkMode();
    }.toJS);
  }

  void _checkMode() {
    final url = web.window.location.href.toLowerCase();
    final isNowPresenter = url.contains('presenter');
    if (isNowPresenter != _isPresenter) {
      setState(() => _isPresenter = isNowPresenter);
    }
  }

  void _toggleMode() {
    setState(() => _isPresenter = !_isPresenter);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _isPresenter 
            ? PresenterWindow(onExit: _toggleMode) 
            : StageWindow(onTogglePresenter: _toggleMode),
            
        Positioned(
          bottom: 0,
          right: 0,
          width: 50,
          height: 50,
          child: GestureDetector(
            onDoubleTap: _toggleMode,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(color: Colors.transparent),
            ),
          ),
        ),
      ],
    );
  }
}

// --- SYNC ---
const String kChannelName = 'ebf_ai_channel';
final web.BroadcastChannel _syncChannel = web.BroadcastChannel(kChannelName);

void broadcastSlide(int index) {
  final message = {'type': 'slide_change', 'index': index}.jsify();
  _syncChannel.postMessage(message);
  web.window.localStorage.setItem('last_index', index.toString());
}

int? getStoredIndex() {
  final stored = web.window.localStorage.getItem('last_index');
  return stored != null ? int.tryParse(stored) : null;
}

// --- LYRIC MODEL ---
class Lyric {
  final Duration time;
  final String text;
  Lyric(this.time, this.text);
}

// --- STAGE WINDOW ---
class StageWindow extends StatefulWidget {
  final VoidCallback onTogglePresenter;
  const StageWindow({super.key, required this.onTogglePresenter});

  @override
  State<StageWindow> createState() => _StageWindowState();
}

class _StageWindowState extends State<StageWindow> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;
  bool _showControls = false;
  int _logoClicks = 0;

  // Audio Logic
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _isLoadingAudio = false;
  bool _needsUserInteraction = true;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  List<Lyric> _lyrics = [];

  @override
  void initState() {
    super.initState();
    _loadLyrics();
    _setupAudio();
    _listenForSync();
    
    final index = getStoredIndex();
    if (index != null) {
      _currentIndex = index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) _pageController.jumpToPage(_currentIndex);
        _handleSlideChange(_currentIndex);
      });
    }
  }

  Future<void> _loadLyrics() async {
    try {
      final lrcString = await rootBundle.loadString('assets/lyrics.lrc');
      final lines = lrcString.split('\n');
      final regExp = RegExp(r'\[(\d+):(\d+\.\d+)\](.*)');
      
      List<Lyric> parsed = [];
      for (var line in lines) {
        final match = regExp.firstMatch(line);
        if (match != null) {
          final minutes = int.parse(match.group(1)!);
          final seconds = double.parse(match.group(2)!);
          final text = match.group(3)!.trim();
          if (text.isNotEmpty && !text.startsWith('[')) {
            parsed.add(Lyric(
              Duration(minutes: minutes, milliseconds: (seconds * 1000).toInt()),
              text,
            ));
          }
        }
      }
      setState(() => _lyrics = parsed);
    } catch (e) {
      developer.log("Error loading lyrics: $e");
    }
  }

  void _setupAudio() {
    _audioPlayer.onDurationChanged.listen((d) => setState(() => _duration = d));
    _audioPlayer.onPositionChanged.listen((p) => setState(() => _position = p));
    _audioPlayer.onPlayerStateChanged.listen((s) {
      setState(() {
        _isPlaying = s == PlayerState.playing;
        if (s == PlayerState.playing) _needsUserInteraction = false;
      });
    });
    
    // Set source early
    _audioPlayer.setSource(AssetSource('essex_rising.mp3')).catchError((e) {
      developer.log("Source set error: $e");
    });
  }

  Future<void> _startAudio() async {
    if (_isLoadingAudio) return;
    
    developer.log("Attempting to start audio...");
    setState(() => _isLoadingAudio = true);
    
    try {
      await _audioPlayer.play(AssetSource('essex_rising.mp3'));
      setState(() {
        _needsUserInteraction = false;
        _isLoadingAudio = false;
      });
      developer.log("Audio play request successful.");
    } catch (e) {
      setState(() => _isLoadingAudio = false);
      developer.log("Audio play error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Audio Error: $e. Try clicking again."),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _handleSlideChange(int index) {
    if (index == 0) {
      if (!_needsUserInteraction) {
        _audioPlayer.resume();
      }
    } else {
      _audioPlayer.pause();
    }
  }

  void _listenForSync() {
    _syncChannel.onmessage = (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is Map && data['type'] == 'slide_change') {
        final index = data['index'] as int;
        if (index != _currentIndex) _updateInternalPage(index);
      }
    }.toJS;
  }

  void _updateInternalPage(int index) {
    if (_pageController.hasClients) {
      _pageController.animateToPage(index, duration: const Duration(milliseconds: 800), curve: Curves.easeOutExpo);
    }
    _handleSlideChange(index);
    setState(() => _currentIndex = index);
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  AudioControlState get _audioState => AudioControlState(
    isPlaying: _isPlaying,
    isMuted: _isMuted,
    duration: _duration,
    position: _position,
    onPlayPause: () {
      if (_needsUserInteraction) {
        _startAudio();
      } else {
        _isPlaying ? _audioPlayer.pause() : _audioPlayer.resume();
      }
    },
    onMute: () {
      _isMuted = !_isMuted;
      _audioPlayer.setVolume(_isMuted ? 0 : 1);
      setState(() {});
    },
    onSeek: (val) => _audioPlayer.seek(Duration(milliseconds: val.toInt())),
  );

  @override
  Widget build(BuildContext context) {
    final List<Widget> slides = [
      SlideTitle(
        onNext: () => _step(1),
        audioState: _audioState,
        lyrics: _lyrics,
        position: _position,
        needsInteraction: _needsUserInteraction,
        isLoading: _isLoadingAudio,
        onStart: _startAudio,
      ),
      const SlideBusinessNow(),
      const IndustrySlide(),
      const SlideHomeAutomation(),
      const PolicyImperativeSlide(),
      const AccuracySlide(),
      const SecuritySlide(),
      const SlideAccountability(),
      const SlidePolicyDraft(),
      const FinalSlide(),
    ];

    return Scaffold(
      backgroundColor: kDeepSlate,
      body: MouseRegion(
        onHover: (_) => setState(() => _showControls = true),
        onExit: (_) => setState(() => _showControls = false),
        child: GestureDetector(
          onTap: () {
            if (_needsUserInteraction && _currentIndex == 0) _startAudio();
            FocusScope.of(context).requestFocus(FocusNode());
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
              const SingleActivator(LogicalKeyboardKey.space): () => _step(1),
            },
            child: Focus(
              autofocus: true,
              child: Stack(
                children: [
                  const AnimatedBackground(),
                  const Positioned.fill(child: ParticleOverlay()),
                  PageView.builder(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: slides.length,
                    itemBuilder: (context, index) {
                      final widget = (index == 0) 
                        ? SlideTitle(onNext: () => _step(1), audioState: _audioState, lyrics: _lyrics, position: _position, needsInteraction: _needsUserInteraction, isLoading: _isLoadingAudio, onStart: _startAudio)
                        : slides[index];
                        
                      return AnimatedSlideWrapper(
                        isActive: _currentIndex == index,
                        child: widget,
                      );
                    },
                  ),
                  
                  Positioned(
                    top: 25,
                    left: 40,
                    child: GestureDetector(
                      onTap: () {
                        _logoClicks++;
                        if (_logoClicks >= 3) { widget.onTogglePresenter(); _logoClicks = 0; }
                        Future.delayed(const Duration(seconds: 2), () => _logoClicks = 0);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: kFuchsia.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kFuchsiaAccent.withValues(alpha: 0.2)),
                        ),
                        child: Text('EBF × AI',
                            style: GoogleFonts.spaceGrotesk(
                                letterSpacing: 4, fontSize: 20, color: kFuchsiaAccent, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ),

                  AnimatedOpacity(
                    opacity: _showControls ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 30),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _navButton(Icons.arrow_back_ios_new, () => _step(-1), enabled: _currentIndex > 0),
                            const SizedBox(width: 20),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: kFuchsia.withValues(alpha: 0.2),
                                border: Border.all(color: kFuchsiaAccent.withValues(alpha: 0.5)),
                                borderRadius: BorderRadius.circular(30),
                              ),
                              child: Text('${_currentIndex + 1} / ${slides.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 20),
                            _navButton(Icons.arrow_forward_ios, () => _step(1), enabled: _currentIndex < slides.length - 1),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, VoidCallback onPressed, {required bool enabled}) {
    return IconButton.filled(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(backgroundColor: kFuchsia, foregroundColor: Colors.white),
    );
  }

  void _step(int delta) {
    final newIndex = _currentIndex + delta;
    if (newIndex >= 0 && newIndex < 10) { 
      _updateInternalPage(newIndex);
      broadcastSlide(newIndex);
    }
  }
}

class AudioControlState {
  final bool isPlaying;
  final bool isMuted;
  final Duration duration;
  final Duration position;
  final VoidCallback onPlayPause;
  final VoidCallback onMute;
  final ValueChanged<double> onSeek;
  AudioControlState({
    required this.isPlaying,
    required this.isMuted,
    required this.duration,
    required this.position,
    required this.onPlayPause,
    required this.onMute,
    required this.onSeek,
  });
}

// --- PRESENTER WINDOW ---
class PresenterWindow extends StatefulWidget {
  final VoidCallback onExit;
  const PresenterWindow({super.key, required this.onExit});

  @override
  State<PresenterWindow> createState() => _PresenterWindowState();
}

class _PresenterWindowState extends State<PresenterWindow> {
  int _currentIndex = 0;
  final int _totalSlides = 10;
  bool _isSynced = true;

  @override
  void initState() {
    super.initState();
    _listenForSync();
    final stored = getStoredIndex();
    if (stored != null) _currentIndex = stored;
  }

  void _listenForSync() {
    _syncChannel.onmessage = (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is Map && data['type'] == 'slide_change') {
        final index = data['index'] as int;
        if (index != _currentIndex) setState(() { _currentIndex = index; _isSynced = true; });
      }
    }.toJS;
  }

  void _goTo(int index) {
    if (index < 0 || index >= _totalSlides) return;
    setState(() { _currentIndex = index; _isSynced = false; });
    broadcastSlide(index);
    Future.delayed(const Duration(milliseconds: 200), () => setState(() => _isSynced = true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _goTo(_currentIndex + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _goTo(_currentIndex - 1),
          const SingleActivator(LogicalKeyboardKey.space): () => _goTo(_currentIndex + 1),
        },
        child: Focus(
          autofocus: true,
          child: Row(
            children: [
              Container(
                width: 350,
                padding: const EdgeInsets.all(32),
                decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white10))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text('PARTY CONTROL 🕴️', style: GoogleFonts.spaceGrotesk(color: kFuchsia, fontSize: 20, fontWeight: FontWeight.w900)),
                      const Spacer(),
                      IconButton(onPressed: widget.onExit, icon: const Icon(Icons.close, color: Colors.white38)),
                    ]),
                    const SizedBox(height: 20),
                    Row(children: [
                      Icon(Icons.link, size: 16, color: _isSynced ? Colors.greenAccent : Colors.orangeAccent),
                      const SizedBox(width: 8),
                      Text(_isSynced ? 'STAGE LINKED' : 'PUSHING...', 
                           style: TextStyle(color: _isSynced ? Colors.greenAccent : Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ]),
                    const Spacer(),
                    Text('SLIDE', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), letterSpacing: 2)),
                    Text('${_currentIndex + 1} / $_totalSlides', style: const TextStyle(color: Colors.white, fontSize: 60, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 30),
                    Row(children: [
                      _bigControl(Icons.chevron_left, () => _goTo(_currentIndex - 1), enabled: _currentIndex > 0),
                      const SizedBox(width: 16),
                      _bigControl(Icons.chevron_right, () => _goTo(_currentIndex + 1), enabled: _currentIndex < _totalSlides - 1),
                    ]),
                    const SizedBox(height: 40),
                    Text('JUMP TO...', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), letterSpacing: 2)),
                    _jumpLink('Intro', 0, Icons.rocket_launch),
                    _jumpLink('Business Today', 1, Icons.business),
                    _jumpLink('EBF Use Cases', 2, Icons.group),
                    _jumpLink('Smart Home', 3, Icons.home_work),
                    _jumpLink('The Rulebook', 4, Icons.shield),
                    _jumpLink('Accuracy', 5, Icons.psychology),
                    _jumpLink('Privacy', 6, Icons.lock),
                    _jumpLink('Accountability', 7, Icons.person),
                    _jumpLink('Draft Policy', 8, Icons.description),
                    _jumpLink('Let\'s Go!', 9, Icons.celebration),
                    const Spacer(),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(80),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('WHAT TO SAY', style: GoogleFonts.spaceGrotesk(color: kFuchsia, fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 30),
                      Expanded(
                        child: SingleChildScrollView(
                          key: ValueKey(_currentIndex),
                          child: Text(_presenterScripts[_currentIndex], style: GoogleFonts.spaceGrotesk(color: Colors.white, fontSize: 28, height: 1.5)),
                        ),
                      ),
                      const SizedBox(height: 40),
                      Text('COMING UP:', style: TextStyle(color: Colors.white10, fontWeight: FontWeight.bold)),
                      Text(_currentIndex < _totalSlides - 1 ? 'Slide ${_currentIndex + 2}' : 'Wrap Up', style: const TextStyle(color: Colors.white38, fontSize: 20)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigControl(IconData icon, VoidCallback onPressed, {required bool enabled}) {
    return Expanded(
      child: IconButton.filled(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 40),
        padding: const EdgeInsets.symmetric(vertical: 24),
        style: IconButton.styleFrom(backgroundColor: kFuchsia, disabledBackgroundColor: Colors.white10),
      ),
    );
  }

  Widget _jumpLink(String label, int index, IconData icon) {
    return TextButton.icon(
      onPressed: () => _goTo(index),
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 16)),
      style: TextButton.styleFrom(foregroundColor: _currentIndex == index ? kFuchsia : Colors.white60, alignment: Alignment.centerLeft),
    );
  }
}

// --- ANIMATION COMPONENTS ---
class AnimatedSlideWrapper extends StatelessWidget {
  final Widget child;
  final bool isActive;
  const AnimatedSlideWrapper({super.key, required this.child, required this.isActive});
  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isActive ? 1.0 : 0.8,
      duration: const Duration(milliseconds: 1200),
      curve: Curves.elasticOut,
      child: AnimatedOpacity(opacity: isActive ? 1.0 : 0.0, duration: const Duration(milliseconds: 600), child: child),
    );
  }
}

class AnimatedBackground extends StatefulWidget {
  const AnimatedBackground({super.key});
  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 10))..repeat();
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(math.sin(_controller.value * 2 * math.pi) * 0.5, math.cos(_controller.value * 2 * math.pi) * 0.5),
              radius: 1.5,
              colors: const [Color(0xFF2E1065), Color(0xFF0F172A)],
            ),
          ),
        );
      },
    );
  }
}

class ParticleOverlay extends StatefulWidget {
  const ParticleOverlay({super.key});
  @override
  State<ParticleOverlay> createState() => _ParticleOverlayState();
}

class _ParticleOverlayState extends State<ParticleOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<_Particle> _particles = List.generate(30, (_) => _Particle());
  @override
  void initState() { super.initState(); _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(); }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: _controller, builder: (context, child) {
      return CustomPaint(painter: _ParticlePainter(_particles, _controller.value));
    });
  }
}

class _Particle {
  double x = math.Random().nextDouble();
  double y = math.Random().nextDouble();
  double size = math.Random().nextDouble() * 3 + 1;
  double speed = math.Random().nextDouble() * 0.002 + 0.001;
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double animationValue;
  _ParticlePainter(this.particles, this.animationValue);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = kFuchsia.withValues(alpha: 0.1);
    for (var p in particles) {
      p.y -= p.speed; if (p.y < 0) p.y = 1.0;
      canvas.drawCircle(Offset(p.x * size.width, p.y * size.height), p.size, paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// --- SLIDE CONTENT ---
class SlideTitle extends StatelessWidget {
  final VoidCallback onNext;
  final AudioControlState audioState;
  final List<Lyric> lyrics;
  final Duration position;
  final bool needsInteraction;
  final bool isLoading;
  final VoidCallback onStart;

  const SlideTitle({
    super.key,
    required this.onNext,
    required this.audioState,
    required this.lyrics,
    required this.position,
    required this.needsInteraction,
    required this.isLoading,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final currentLyric = lyrics.lastWhere(
      (l) => l.time <= position,
      orElse: () => Lyric(Duration.zero, ''),
    );

    return Stack(
      children: [
        // Synced Lyric Background
        Center(
          child: AnimatedOpacity(
            opacity: currentLyric.text.isEmpty ? 0.0 : 0.2,
            duration: const Duration(milliseconds: 500),
            child: Text(
              currentLyric.text.toUpperCase(),
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 100,
                fontWeight: FontWeight.w900,
                color: kFuchsiaAccent,
              ),
            ),
          ),
        ),
        
        // Main Title
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                decoration: BoxDecoration(
                  color: kFuchsia.withValues(alpha: 0.1),
                  border: Border.all(color: kFuchsia),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text('ESSEX BUSINESS FORUM 2026',
                    style: GoogleFonts.spaceGrotesk(color: kFuchsia, fontWeight: FontWeight.w900, letterSpacing: 4)),
              ),
              const SizedBox(height: 60),
              Stack(
                alignment: Alignment.center,
                children: [
                  Transform.translate(
                    offset: const Offset(8, 8),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'THE AI ADVANTAGE',
                        style: GoogleFonts.spaceGrotesk(fontSize: 140, fontWeight: FontWeight.w900, height: 0.8, letterSpacing: -8, color: kFuchsia.withValues(alpha: 0.3)),
                      ),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'THE AI ADVANTAGE',
                      style: GoogleFonts.spaceGrotesk(fontSize: 140, fontWeight: FontWeight.w900, height: 0.8, letterSpacing: -8, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.rocket_launch, color: kCyanAccent, size: 36),
                  const SizedBox(width: 15),
                  Text('Get More Done. Worry Less. Have More Fun.', style: GoogleFonts.spaceGrotesk(fontSize: 36, color: kCyanAccent, fontWeight: FontWeight.w500)),
                ],
              ),
              const SizedBox(height: 80),
              if (needsInteraction)
                SizedBox(
                  width: 300,
                  height: 80,
                  child: ElevatedButton.icon(
                    onPressed: isLoading ? null : onStart,
                    icon: isLoading 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.play_arrow, size: 32),
                    label: Text(isLoading ? "LOADING..." : "START EXPERIENCE", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kFuchsia,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                    ),
                  ),
                )
              else
                GestureDetector(onTap: onNext, child: const MouseRegion(cursor: SystemMouseCursors.click, child: AnimatedPulseIcon())),
            ],
          ),
        ),

        // Audio Controls Overlay
        if (!needsInteraction)
          Positioned(
            bottom: 40,
            left: 40,
            right: 40,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(audioState.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 40, color: kFuchsiaAccent),
                    onPressed: audioState.onPlayPause,
                  ),
                  IconButton(
                    icon: Icon(audioState.isMuted ? Icons.volume_off : Icons.volume_up, color: Colors.white70),
                    onPressed: audioState.onMute,
                  ),
                  Expanded(
                    child: Slider(
                      value: audioState.position.inMilliseconds.toDouble(),
                      max: audioState.duration.inMilliseconds.toDouble() > 0 ? audioState.duration.inMilliseconds.toDouble() : 1.0,
                      onChanged: audioState.onSeek,
                      activeColor: kFuchsia,
                      inactiveColor: Colors.white10,
                    ),
                  ),
                  Text(
                    _formatDuration(audioState.position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(d.inMinutes)}:${twoDigits(d.inSeconds.remainder(60))}';
  }
}

class SlideBusinessNow extends StatelessWidget {
  const SlideBusinessNow({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('📈 THE LANDSCAPE', style: GoogleFonts.spaceGrotesk(color: kCyanAccent, fontWeight: FontWeight.w900, letterSpacing: 2)),
          Text('AI in Business Today', style: GoogleFonts.spaceGrotesk(fontSize: 80, fontWeight: FontWeight.w900)),
          const SizedBox(height: 40),
          Row(
            children: [
              _infoBox('35%', 'Current UK SME AI adoption rate.', Icons.trending_up, kFuchsia),
              const SizedBox(width: 30),
              _infoBox('31%', 'Boost in employee productivity.', Icons.bolt, kCyanAccent),
              const SizedBox(width: 30),
              _infoBox('23%', 'Reduction in operational costs.', Icons.savings, Colors.amberAccent),
            ],
          ),
          const SizedBox(height: 40),
          const Text('Fact: Over 67% of SME leaders cite the "Skills Gap" as their biggest barrier. (Ref: British Chambers of Commerce 2025)', style: TextStyle(color: Colors.white38, fontSize: 16)),
        ],
      ),
    );
  }
  Widget _infoBox(String val, String label, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(32), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Column(children: [
          Icon(icon, color: color, size: 48),
          const SizedBox(height: 20),
          Text(val, style: GoogleFonts.spaceGrotesk(fontSize: 50, fontWeight: FontWeight.w900, color: color)),
          const SizedBox(height: 10),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.white70)),
        ]),
      ),
    );
  }
}

class IndustrySlide extends StatelessWidget {
  const IndustrySlide({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(60, 100, 60, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.check_circle, color: kCyanAccent, size: 24), const SizedBox(width: 10), Text('QUICK WINS', style: GoogleFonts.spaceGrotesk(color: kCyanAccent, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 2))]),
        Text('AI for EBF Members', style: GoogleFonts.spaceGrotesk(fontSize: 60, fontWeight: FontWeight.w900, color: Colors.white)),
        const SizedBox(height: 30),
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          return GridView.count(
            crossAxisCount: 3, mainAxisSpacing: 25, crossAxisSpacing: 25, physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: (constraints.maxWidth / 3) / (constraints.maxHeight / 2.2),
            children: const [
              InteractiveIndustryCard(icon: Icons.gavel_rounded, title: 'Solicitors & IFAs', content: 'Audit 100-page leases in 5 seconds. Securely.', color: Color(0xFFD946EF), software: ['CoCounsel', 'Harvey AI'], prompt: 'Summarize this lease and highlight all termination clauses.'),
              InteractiveIndustryCard(icon: Icons.plumbing_rounded, title: 'Trades & Builders', content: 'AI photo-quoting. Instant drafts from site pics.', color: Color(0xFF06B6D4), software: ['Hover.to', 'ArcSite'], prompt: 'Estimate material costs from these three site photos.'),
              InteractiveIndustryCard(icon: Icons.rocket_launch_rounded, title: 'Creatives', content: 'Generative ideation & SEO that works.', color: Color(0xFFF59E0B), software: ['Midjourney', 'Jasper'], prompt: 'Generate 10 catchy taglines for a local Essex bakery.'),
              InteractiveIndustryCard(icon: Icons.shopping_cart_rounded, title: 'Retailers', content: 'Demand forecasting to optimize stock levels.', color: Color(0xFF10B981), software: ['Shopify Magic', 'Dynamic Yield'], prompt: 'Analyze sales data to predict stock needs for June.'),
              InteractiveIndustryCard(icon: Icons.spa_rounded, title: 'Health & Wellness', content: 'Admin reduction & 24/7 patient triaging.', color: Color(0xFFEF4444), software: ['Nabla Copilot', 'Cliniko'], prompt: 'Draft follow-up summary for a 15-minute consultation.'),
              InteractiveIndustryCard(icon: Icons.help_outline_rounded, title: 'Everyone Else', content: 'Inbox zero. Meeting intel. Focus on growth.', color: Color(0xFF6366F1), software: ['MS Copilot', 'ChatGPT Ent.'], prompt: 'Draft an agenda based on my priority emails.'),
            ],
          );
        })),
      ]),
    );
  }
}

class SlideHomeAutomation extends StatelessWidget {
  const SlideHomeAutomation({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('🏠 AI AT HOME', style: GoogleFonts.spaceGrotesk(color: Colors.amberAccent, fontWeight: FontWeight.w900, letterSpacing: 2)),
        Text('The Personal Edge', style: GoogleFonts.spaceGrotesk(fontSize: 80, fontWeight: FontWeight.w900)),
        const SizedBox(height: 40),
        Row(children: [
          _homeTile('Presence Awareness', 'Lights and climate follow you via AI room-tracking.', Icons.person_pin_circle_rounded, kCyanAccent),
          const SizedBox(width: 25),
          _homeTile('High Impact Safety', 'Auto water shut-off for leaks & fire exit illumination.', Icons.shield_rounded, Colors.redAccent),
        ]),
        const SizedBox(height: 25),
        Row(children: [
          _homeTile('Home Assistant', 'The open-source hub for local-first private AI control.', Icons.hub_rounded, Colors.blueAccent),
          const SizedBox(width: 25),
          _homeTile('Predictive Energy', 'AI HVAC slashes bills by 26% based on your habits.', Icons.eco_rounded, Colors.greenAccent),
        ]),
        const SizedBox(height: 30),
        const InfoAlert(text: 'Safety Fact: AI systems like Flo or Phyn learn your "Water Fingerprint" to detect leaks as small as one drop per minute.'),
      ]),
    );
  }
  Widget _homeTile(String title, String desc, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(24), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Column(children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 20),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          const SizedBox(height: 10),
          Text(desc, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
        ]),
      ),
    );
  }
}

class InfoAlert extends StatelessWidget {
  final String text;
  const InfoAlert({super.key, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: kCyanAccent.withValues(alpha: 0.1), border: Border.all(color: kCyanAccent.withValues(alpha: 0.3)), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [const Icon(Icons.lightbulb, color: kCyanAccent), const SizedBox(width: 15), Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)))]),
    );
  }
}

class PolicyImperativeSlide extends StatelessWidget {
  const PolicyImperativeSlide({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.auto_fix_high_rounded, size: 100, color: kFuchsia),
        const SizedBox(height: 20),
        FittedBox(fit: BoxFit.scaleDown, child: Text('THE RULEBOOK', style: GoogleFonts.spaceGrotesk(fontSize: 100, fontWeight: FontWeight.w900))),
        const SizedBox(height: 40),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _buildPillar('TRUTH', Icons.fact_check_rounded, kCyanAccent),
          _buildPillar('LOCKDOWN', Icons.lock_rounded, kFuchsia),
          _buildPillar('YOU', Icons.person_rounded, Colors.amberAccent),
        ]),
        const SizedBox(height: 50),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.warning, color: Colors.amberAccent, size: 24),
          const SizedBox(width: 10),
          Text('Reputation is hard to build, easy for a chatbot to ruin.', style: GoogleFonts.spaceGrotesk(fontSize: 24, color: Colors.white60)),
        ]),
      ]),
    );
  }
  Widget _buildPillar(String label, IconData icon, Color color) {
    return Container(
      width: 200, margin: const EdgeInsets.symmetric(horizontal: 20), padding: const EdgeInsets.all(35),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.05), border: Border.all(color: color.withValues(alpha: 0.3), width: 2), borderRadius: BorderRadius.circular(32)),
      child: Column(children: [
        Icon(icon, size: 50, color: color),
        const SizedBox(height: 20),
        Text(label, style: GoogleFonts.spaceGrotesk(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
      ]),
    );
  }
}

class AccuracySlide extends StatelessWidget {
  const AccuracySlide({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.check_circle, color: kCyanAccent, size: 24), const SizedBox(width: 10), Text('STEP 01', style: GoogleFonts.spaceGrotesk(color: kCyanAccent, fontWeight: FontWeight.w900, letterSpacing: 2))]),
        FittedBox(fit: BoxFit.scaleDown, child: Text('Kill the Hallucinations', style: GoogleFonts.spaceGrotesk(fontSize: 80, fontWeight: FontWeight.w900))),
        const SizedBox(height: 40),
        Row(children: [
          _buildCard('RAG (Grounded Data)', 'Connect AI to your PDFs and Data. It only talks about what it KNOWS.', Icons.dns_rounded),
          const SizedBox(width: 30),
          _buildCard('Human Approval', 'AI is the Intern, You are the Boss. Every output needs a Human "OK".', Icons.verified_user_rounded),
        ]),
      ]),
    );
  }
  Widget _buildCard(String title, String desc, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(40), border: Border.all(color: Colors.white10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: kCyanAccent, size: 50),
          const SizedBox(height: 24),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Text(desc, style: const TextStyle(color: Colors.white60, fontSize: 18, height: 1.4)),
        ]),
      ),
    );
  }
}

class SecuritySlide extends StatelessWidget {
  const SecuritySlide({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.check_circle, color: kFuchsia, size: 24), const SizedBox(width: 10), Text('STEP 02', style: GoogleFonts.spaceGrotesk(color: kFuchsia, fontWeight: FontWeight.w900, letterSpacing: 2))]),
        FittedBox(fit: BoxFit.scaleDown, child: Text('Lock Down the Data', style: GoogleFonts.spaceGrotesk(fontSize: 80, fontWeight: FontWeight.w900))),
        const SizedBox(height: 50),
        _buildSecurityRow('No Public Leakage', 'Never put client PII into a public chatbot. Use Enterprise APIs.', Icons.lock_person_rounded),
        _buildSecurityRow('GDPR is Still Boss', 'You are the controller. Compliance is your responsibility.', Icons.balance_rounded),
        _buildSecurityRow('Total Transparency', 'Tell your clients how you use AI to improve their experience.', Icons.visibility_rounded),
      ]),
    );
  }
  Widget _buildSecurityRow(String title, String desc, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(children: [
        Icon(icon, color: kFuchsia, size: 40),
        const SizedBox(width: 30),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
          Text(desc, style: const TextStyle(fontSize: 20, color: Colors.white60)),
        ])),
      ]),
    );
  }
}

class SlideAccountability extends StatelessWidget {
  const SlideAccountability({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.check_circle, color: Colors.amberAccent, size: 24), const SizedBox(width: 10), Text('STEP 03', style: GoogleFonts.spaceGrotesk(color: Colors.amberAccent, fontWeight: FontWeight.w900, letterSpacing: 2))]),
        FittedBox(fit: BoxFit.scaleDown, child: Text('You are the Anchor', style: GoogleFonts.spaceGrotesk(fontSize: 80, fontWeight: FontWeight.w900))),
        const SizedBox(height: 40),
        Row(children: [
          _buildPolicyTile('Professional Liability', 'PI Insurance rarely covers unverified AI advice. You sign it, you own it.', Icons.history_edu_rounded),
          const SizedBox(width: 30),
          _buildPolicyTile('Client Trust', 'Transparency builds loyalty. Hidden AI usage destroys it.', Icons.handshake_rounded),
        ]),
        const SizedBox(height: 40),
        const InfoAlert(text: 'Key Principle: AI "Suggests", Humans "Decide". Never delegate final judgment to a model.'),
      ]),
    );
  }
  Widget _buildPolicyTile(String title, String desc, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(40), border: Border.all(color: Colors.amber.withValues(alpha: 0.2))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Colors.amberAccent, size: 50),
          const SizedBox(height: 24),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Text(desc, style: const TextStyle(color: Colors.white60, fontSize: 18, height: 1.4)),
        ]),
      ),
    );
  }
}

class SlidePolicyDraft extends StatelessWidget {
  const SlidePolicyDraft({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 80),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('🛡️ THE BLUEPRINT', style: GoogleFonts.spaceGrotesk(color: kFuchsia, fontWeight: FontWeight.w900, letterSpacing: 2)),
        Text('Essential Policy Components', style: GoogleFonts.spaceGrotesk(fontSize: 60, fontWeight: FontWeight.w900)),
        const SizedBox(height: 40),
        Expanded(
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _policyRow('1. Approved Tool List', 'Explicitly state which tools are allowed for business data.'),
              _policyRow('2. Data Prohibition', 'Strictly ban uploading client PII to public/free chatbots.'),
              _policyRow('3. Verification Workflow', 'Mandatory double-check of all AI-generated facts/advice.'),
              _policyRow('4. Client Disclosure', 'Standard wording for how/when clients are told AI was used.'),
              _policyRow('5. Accountability Lead', 'Identify who in the firm is responsible for AI oversight.'),
            ],
          ),
        ),
      ]),
    );
  }
  Widget _policyRow(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const Icon(Icons.description, color: kFuchsiaAccent, size: 24),
        const SizedBox(width: 20),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Colors.white)),
        const SizedBox(width: 20),
        Expanded(child: Text(desc, style: const TextStyle(color: Colors.white60, fontSize: 18))),
      ]),
    );
  }
}

class FinalSlide extends StatelessWidget {
  const FinalSlide({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.celebration, size: 80, color: Colors.amberAccent),
        const SizedBox(height: 20),
        FittedBox(fit: BoxFit.scaleDown, child: Text('LEAD THE WAY', style: GoogleFonts.spaceGrotesk(fontSize: 120, fontWeight: FontWeight.w900))),
        const SizedBox(height: 20),
        Text('The EBF is the future of Essex business.', style: GoogleFonts.spaceGrotesk(fontSize: 28, color: kCyanAccent, fontWeight: FontWeight.w600)),
        const SizedBox(height: 60),
        ElevatedButton.icon(
          onPressed: () {}, icon: const Icon(Icons.forum, size: 28), label: const Text('LET\'S TALK AI', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 30), backgroundColor: kFuchsia, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100))),
        ),
        const SizedBox(height: 40),
        const Text('Thank you, Essex Business Forum!', style: TextStyle(color: Colors.white38)),
      ]),
    );
  }
}

// --- INTERACTIVE ELEMENTS ---
class InteractiveIndustryCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String content;
  final Color color;
  final List<String> software;
  final String prompt;
  const InteractiveIndustryCard({super.key, required this.icon, required this.title, required this.content, required this.color, required this.software, required this.prompt});
  @override
  State<InteractiveIndustryCard> createState() => _InteractiveIndustryCardState();
}
class _InteractiveIndustryCardState extends State<InteractiveIndustryCard> with SingleTickerProviderStateMixin {
  late AnimationController _controller; late Animation<double> _animation; bool _isHovered = false;
  @override
  void initState() { super.initState(); _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 600)); _animation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutExpo)); }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  void _onEnter() { setState(() => _isHovered = true); _controller.forward(); }
  void _onExit() { setState(() => _isHovered = false); _controller.reverse(); }
  @override
  Widget build(BuildContext context) {
    return MouseRegion(onEnter: (_) => _onEnter(), onExit: (_) => _onExit(), child: AnimatedBuilder(animation: _animation, builder: (context, child) {
      final isBack = _animation.value > 0.5; final angle = _animation.value * math.pi;
      return Transform(transform: Matrix4.identity()..setEntry(3, 2, 0.001)..rotateY(angle), alignment: Alignment.center, child: isBack ? Transform(transform: Matrix4.identity()..rotateY(math.pi), alignment: Alignment.center, child: _buildCard(true)) : _buildCard(false));
    }));
  }
  Widget _buildCard(bool isBack) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: isBack ? widget.color : Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(32), border: Border.all(color: widget.color.withValues(alpha: 0.5), width: 2), boxShadow: [if (_isHovered) BoxShadow(color: widget.color.withValues(alpha: 0.4), blurRadius: 30, offset: const Offset(0, 10))]),
      child: isBack ? _buildBack() : _buildFront(),
    );
  }
  Widget _buildFront() {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(widget.icon, size: 48, color: widget.color), const SizedBox(height: 20), FittedBox(fit: BoxFit.scaleDown, child: Text(widget.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white))), const SizedBox(height: 12), Text(widget.content, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15))]);
  }
  Widget _buildBack() {
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('TOOLS:', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Colors.white60)),
      const SizedBox(height: 5), Text(widget.software.join(' • '), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
      const Divider(color: Colors.white24, height: 25),
      const Text('TRY THIS PROMPT:', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Colors.white60)),
      const SizedBox(height: 5), Text('"${widget.prompt}"', style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 14, color: Colors.white, height: 1.3)),
    ]);
  }
}

class AnimatedPulseIcon extends StatefulWidget {
  const AnimatedPulseIcon({super.key});
  @override
  State<AnimatedPulseIcon> createState() => _AnimatedPulseIconState();
}
class _AnimatedPulseIconState extends State<AnimatedPulseIcon> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() { super.initState(); _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true); }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: Tween<double>(begin: 1.0, end: 1.3).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut)), child: const Icon(Icons.keyboard_double_arrow_down_rounded, size: 70, color: kFuchsia));
  }
}

// --- SCRIPTS ---
final List<String> _presenterScripts = [
  "Good morning everyone. It’s great to be with the Essex Business Forum today. We’re going to look past the hype and headlines to focus on the 'AI Advantage'. This isn’t about science fiction; it’s about practical tools that can help us get more done, reduce our daily admin stress, and allow us to focus on the parts of our business we actually enjoy. Over the next 10 minutes, I’ll share real-world wins and the essential safeguards you need to protect your reputation.",
  
  "Before we dive into the tools, let’s look at the data. As of 2025, 35% of UK SMEs have fully integrated AI into their operations, and that adoption is accelerating. This isn't just for big tech firms; local businesses are seeing a 31% jump in productivity and a 23% reduction in operational costs. However, the 'Skills Gap' remains the biggest hurdle for 67% of leaders. Today, we’re going to help bridge that gap by looking at simple, high-impact implementation.",
  
  "Let's look at how this applies to our members. For Solicitors, AI like CoCounsel can audit massive leases in seconds. For our Trades, imagine a client sending a photo of a job and AI drafting an initial quote before you even get in your van. Creative agencies use 'Generative Ideation' to skip the blank-page syndrome. These are 'Quick Wins' that buy your time back from the admin gods. Feel free to hover over the cards here to see the specific software and prompts I recommend.",
  
  "It’s not just the office where AI is making an impact. In our personal lives, 'The Personal Edge' is about safety and efficiency. Tools like Home Assistant allow for 'Local-First' AI—meaning your data stays in your house, not the cloud. We’re seeing 'Presence Awareness' that adjusts lighting as you move, and high-impact safety like AI leak detection that can shut your water main off in seconds if it detects a burst pipe at 2 AM. It's about AI acting as a guardian for your home.",
  
  "Now, for the most critical section: The Rulebook. In the EBF, we value our local reputations. You cannot just 'set and forget' AI. A proper policy is built on three pillars: Truth (Accuracy), Lockdown (Security), and You (Accountability). This policy is your shield against the risks of unmanaged automation, ensuring that every tool you use adds value without creating a liability.",
  
  "The biggest fear with AI is 'Hallucinations'—when a bot makes up a fact with total confidence. The solution is RAG, or 'Retrieval-Augmented Generation'. Instead of asking an AI to use its general training memory, we connect it specifically to *your* PDFs and databases. It only answers using the facts you provide. But even with RAG, we keep a 'Human in the Loop'. AI is your intern—it does the heavy lifting, but an expert must always give the final sign-off.",
  
  "Pillar 2 is Data Lockdown. Under UK GDPR, you are the data controller. If you enter sensitive client information into a public, free version of ChatGPT, you have essentially leaked that data. Your policy must mandate the use of 'Enterprise APIs' where data is explicitly not used for training. Be transparent with your clients—tell them you use AI to improve their service, and show them the security measures you have in place to keep their data private.",

  "Pillar 3 is 'You'—Accountability. As a business owner, you are the anchor. Professional Indemnity Insurance rarely covers advice given by an unverified AI. If the AI suggests a legal course of action or a financial strategy, and you sign it off, you own that outcome. Transparency builds trust. If you're using AI to draft reports or analyze data, tell your clients. They will value the efficiency if they know you are still the one making the final expert judgment.",

  "So, what should your policy actually look like? It needs to be a living document. Start with an 'Approved Tool List' so your team knows what's safe. Strictly prohibit client PII in public bots. Mandate a verification workflow for every fact. Establish a disclosure standard for clients. Finally, appoint an 'Accountability Lead' who stays on top of new AI developments. This isn't just about protection—it's about professionalism.",
  
  "AI is the ultimate force multiplier for Essex business. My advice? Don't try to change everything at once. Pick one 'Quick Win', draft your policy, and stay curious. The EBF has always been about leading the way, and with these tools, we're in a position to stay ahead of the curve. Thank you for your time today—I'd love to hear your thoughts and answer any questions you might have. Let's talk AI!"
];
