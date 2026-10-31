import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

bool terminalHasTextAt(TerminalViewState view, Offset globalPosition) {
  final render = view.renderTerminal;
  final local = render.globalToLocal(globalPosition);
  final cell = render.getCellOffset(local);
  // Offsets below the buffer are clamped by xterm; they are still blank.
  if (local.dy >= render.getOffset(cell).dy + render.lineHeight) return false;
  final line = view.widget.terminal.buffer.lines[cell.y];
  var x = cell.x;
  if (x > 0 && line.getWidth(x) == 0 && line.getWidth(x - 1) == 2) x--;
  final code = line.getCodePoint(x);
  return code != 0 && code != 32;
}

/// Owns no anchors: TerminalController owns and disposes each fresh pair.
class TerminalSelection {
  TerminalSelection(this.terminal, this.controller);
  final Terminal terminal;
  final TerminalController controller;

  BufferRange? get range =>
      controller.selectionFor(terminal.buffer)?.normalized;
  String get text => range == null ? '' : terminal.buffer.getText(range);

  void select(CellOffset start, CellOffset end) {
    final buffer = terminal.buffer;
    controller.setSelection(
      buffer.createAnchorFromOffset(start),
      buffer.createAnchorFromOffset(end),
      mode: SelectionMode.line,
    );
  }

  void move(bool start, CellOffset cell) {
    final current = range;
    if (current == null) return;
    final line = terminal.buffer.lines[cell.y];
    if (cell.x > 0 &&
        cell.x < line.length &&
        line.getWidth(cell.x) == 0 &&
        line.getWidth(cell.x - 1) == 2) {
      cell = CellOffset(cell.x + (start ? -1 : 1), cell.y);
    }
    // End is exclusive. Keep each handle's identity when endpoints meet.
    if (start && cell.isBefore(current.end)) select(cell, current.end);
    if (!start && cell.isAfter(current.begin)) select(current.begin, cell);
  }

  void selectAll({int maxLines = 2000}) {
    final buffer = terminal.buffer;
    final end = buffer.lines.length - 1;
    if (end < 0) return;
    select(
      CellOffset(0, (end - maxLines + 1).clamp(0, end)),
      CellOffset(buffer.lines[end].length, end),
    );
  }

  void cancel() => controller.clearSelection();
}

/// Handles intercept xterm taps. The parent disables pinch and drawer while a
/// handle is pressed; two fingers elsewhere still reach the zoom listener.
class TerminalSelectionOverlay extends StatefulWidget {
  const TerminalSelectionOverlay({
    super.key,
    required this.terminal,
    required this.controller,
    required this.viewKey,
    required this.scrollController,
    required this.child,
    required this.onPaste,
    this.onHandleDrag,
    this.onBlankLongPress,
    this.onLongPress,
  });
  final Terminal terminal;
  final TerminalController controller;
  final GlobalKey<TerminalViewState> viewKey;
  final ScrollController scrollController;
  final Widget child;
  final Future<void> Function() onPaste;
  final ValueChanged<bool>? onHandleDrag;
  final ValueChanged<Offset>? onBlankLongPress;
  final VoidCallback? onLongPress;

  @override
  State<TerminalSelectionOverlay> createState() =>
      _TerminalSelectionOverlayState();
}

class _TerminalSelectionOverlayState extends State<TerminalSelectionOverlay> {
  final _layerKey = GlobalKey();
  bool _scheduled = false;
  Offset? _dragOrigin;
  Offset? _cellOrigin;
  bool _dragging = false;
  bool _menuOpen = false;
  final _surfacePointers = <int>{};
  bool _surfaceMultiTouch = false;
  Offset? _longPressOrigin;
  TerminalSelection get selection =>
      TerminalSelection(widget.terminal, widget.controller);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    widget.terminal.addListener(_refresh);
    widget.scrollController.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(TerminalSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_refresh);
      widget.terminal.addListener(_refresh);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_refresh);
      widget.scrollController.addListener(_refresh);
    }
    // Geometry can change after font/layout or a session replacement.
    _refresh();
  }

  void _refresh() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    widget.terminal.removeListener(_refresh);
    widget.scrollController.removeListener(_refresh);
    super.dispose();
  }

  void _cancelSelection() {
    _endDrag();
    _surfacePointers.clear();
    selection.cancel();
  }

  void _tapSelection(TapUpDetails details) {
    if (_surfaceMultiTouch || _dragging) return;
    final range = selection.range;
    final render = widget.viewKey.currentState?.renderTerminal;
    if (range == null || render == null) return;
    final local = render.globalToLocal(details.globalPosition);
    final cell = render.getCellOffset(local);
    final inside =
        local.dx >= 0 &&
        local.dx < render.size.width &&
        local.dy >= render.getOffset(range.begin).dy &&
        local.dy < render.getOffset(range.end).dy + render.lineHeight &&
        !cell.isBefore(range.begin) &&
        cell.isBefore(range.end);
    if (!inside) _cancelSelection();
  }

  void _longPressStart(LongPressStartDetails details) {
    if (_surfaceMultiTouch || _dragging) return;
    final view = widget.viewKey.currentState;
    if (view == null) return;
    final render = view.renderTerminal;
    widget.onLongPress?.call();
    final local = render.globalToLocal(details.globalPosition);
    final blank = !terminalHasTextAt(view, details.globalPosition);
    _longPressOrigin = null;
    if (blank && selection.range == null && widget.onBlankLongPress != null) {
      widget.onBlankLongPress!(details.globalPosition);
    } else {
      _longPressOrigin = local;
      render.selectWord(local);
    }
  }

  void _longPressMove(LongPressMoveUpdateDetails details) {
    final render = widget.viewKey.currentState?.renderTerminal;
    if (_surfaceMultiTouch || _longPressOrigin == null || render == null) {
      return;
    }
    render.selectWord(
      _longPressOrigin!,
      render.globalToLocal(details.globalPosition),
    );
  }

  void _scroll(double delta) {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    scroll.jumpTo(
      (scroll.offset + delta).clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      ),
    );
  }

  void _endDrag() {
    _dragOrigin = null;
    _cellOrigin = null;
    if (_dragging) widget.onHandleDrag?.call(false);
    _dragging = false;
  }

  Widget _handle(bool start, Offset point, Size size) {
    // No false endpoint pinned to a different line when it scrolls offscreen.
    if (point.dy < 0 || point.dy > size.height) return const SizedBox.shrink();
    final left = (point.dx - (start ? 48 : 0)).clamp(
      0.0,
      (size.width - 48).clamp(0.0, double.infinity),
    );
    final top = (point.dy - 12).clamp(
      0.0,
      (size.height - 48).clamp(0.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top,
      width: 48,
      height: 48,
      child: Semantics(
        label: start ? 'Início da seleção' : 'Fim da seleção',
        child: GestureDetector(
          key: ValueKey(start ? 'selection-start' : 'selection-end'),
          behavior: HitTestBehavior.opaque,
          onPanDown: (details) {
            _dragging = true;
            widget.onHandleDrag?.call(true);
            _dragOrigin = details.globalPosition;
            final render = widget.viewKey.currentState!.renderTerminal;
            final range = selection.range!;
            _cellOrigin = render.localToGlobal(
              render.getOffset(start ? range.begin : range.end),
            );
          },
          onPanUpdate: (details) {
            if (_dragOrigin == null || _cellOrigin == null) return;
            final render = widget.viewKey.currentState!.renderTerminal;
            final local = render.globalToLocal(
              _cellOrigin! + details.globalPosition - _dragOrigin!,
            );
            if (local.dy < 20) _scroll(-render.lineHeight);
            if (local.dy > render.size.height - 20) _scroll(render.lineHeight);
            var cell = render.getCellOffset(local);
            // Permit the exclusive end at the last column's right edge.
            if (!start &&
                local.dx >=
                    render
                        .getOffset(CellOffset(widget.terminal.viewWidth, 0))
                        .dx) {
              cell = CellOffset(widget.terminal.viewWidth, cell.y);
            }
            selection.move(start, cell);
          },
          onPanEnd: (_) => _endDrag(),
          onPanCancel: _endDrag,
          child: CustomPaint(
            painter: _SelectionHandlePainter(
              Offset(point.dx - left, point.dy - top),
              start,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: (_) {
        if (!_menuOpen && !_dragging) _cancelSelection();
      },
      child: Listener(
        onPointerDown: (e) {
          if (_surfacePointers.isEmpty) _surfaceMultiTouch = false;
          _surfacePointers.add(e.pointer);
          if (_surfacePointers.length > 1) _surfaceMultiTouch = true;
        },
        onPointerUp: (e) => _surfacePointers.remove(e.pointer),
        onPointerCancel: (e) => _surfacePointers.remove(e.pointer),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final range = selection.range;
            final view = widget.viewKey.currentState;
            final layer =
                _layerKey.currentContext?.findRenderObject() as RenderBox?;
            Offset point(CellOffset cell) {
              final render = view!.renderTerminal;
              return layer!.globalToLocal(
                    render.localToGlobal(render.getOffset(cell)),
                  ) +
                  Offset(0, render.lineHeight);
            }

            return Stack(
              key: _layerKey,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(child: widget.child),
                if (widget.onBlankLongPress != null)
                  Positioned.fill(
                    // Translucent with no hit-testing child: xterm still receives
                    // taps, double taps, wheel and scroll gestures. This earlier
                    // arena entry owns only long-press, which xterm cannot override
                    // through a public TerminalView callback.
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onLongPressStart: _longPressStart,
                      onLongPressMoveUpdate: _longPressMove,
                      child: const SizedBox.expand(),
                    ),
                  ),
                if (range != null && view != null && layer != null) ...[
                  // Reserve normal scrolling and taps while selection is persistent.
                  // Parent zoom Listener still receives two-finger gestures on this area.
                  Positioned.fill(
                    child: GestureDetector(
                      // Stop xterm's own tap recognizer from clearing selection
                      // underneath us. Ancestor zoom/drawer still see gestures.
                      behavior: HitTestBehavior.opaque,
                      onTapUp: _tapSelection,
                      onVerticalDragUpdate: (d) {
                        if (!_surfaceMultiTouch &&
                            _surfacePointers.length == 1) {
                          _scroll(-d.delta.dy);
                        }
                      },
                      onLongPressStart: _longPressStart,
                      onLongPressMoveUpdate: _longPressMove,
                    ),
                  ),
                  _handle(true, point(range.begin), constraints.biggest),
                  _handle(false, point(range.end), constraints.biggest),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Material(
                      color: const Color(0xEE192638),
                      borderRadius: BorderRadius.circular(8),
                      child: PopupMenuButton<String>(
                        tooltip: 'Ações da seleção',
                        onOpened: () => _menuOpen = true,
                        onCanceled: () => _menuOpen = false,
                        icon: const Icon(Icons.more_horiz),
                        onSelected: (action) async {
                          _menuOpen = false;
                          switch (action) {
                            case 'copy':
                              await Clipboard.setData(
                                ClipboardData(text: selection.text),
                              );
                            case 'paste':
                              await widget.onPaste();
                            case 'all':
                              selection.selectAll();
                            case 'cancel':
                              _cancelSelection();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'copy', child: Text('Copiar')),
                          PopupMenuItem(value: 'paste', child: Text('Colar')),
                          PopupMenuItem(
                            value: 'all',
                            child: Text('Selecionar tudo (até 2000 linhas)'),
                          ),
                          PopupMenuItem(
                            value: 'cancel',
                            child: Text('Cancelar'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SelectionHandlePainter extends CustomPainter {
  const _SelectionHandlePainter(this.tip, this.start);
  final Offset tip;
  final bool start;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2;
    final center = Offset(
      (tip.dx + (start ? -10 : 10)).clamp(10, size.width - 10),
      (tip.dy + 12).clamp(10, size.height - 10),
    );
    canvas.drawLine(tip, center, paint);
    canvas.drawCircle(center, 10, paint);
  }

  @override
  bool shouldRepaint(_SelectionHandlePainter old) =>
      old.tip != tip || old.start != start;
}
