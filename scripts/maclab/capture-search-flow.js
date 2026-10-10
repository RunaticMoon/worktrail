/*
 * Persisted Maclab capture/search workflow regression driver.
 *
 * Preconditions:
 * - Launch exactly one isolated DEBUG review bundle with --ui-test-fixture many.
 * - Bundle identity must be dev.worklog.UIReview. Never run against a production
 *   data directory or a review process opened without the synthetic fixture.
 * - Accessibility permission and the default fixture hotkeys must be available.
 * - Close open sheets and capture panels before starting. Existing non-test
 *   drafts are refused, not overwritten.
 *
 * Run capture first, then search in the same fixture process:
 *   osascript -l JavaScript scripts/maclab/capture-search-flow.js --action capture
 *   osascript -l JavaScript scripts/maclab/capture-search-flow.js --action search
 * Search global-hotkey coverage can be separated from the local search workflow:
 *   osascript -l JavaScript scripts/maclab/capture-search-flow.js --action search --search-open command-f
 * This explicit mode uses native app activation and AXRaise before CmdF. It does
 * not silently substitute for a failed global hotkey; the output identifies it.
 * For an executor that passes this file as an inline -e program, put a -- between
 * the script and its arguments: osascript -l JavaScript -e SCRIPT -- --action capture
 *
 * Effects: activates TextEdit, uses registered global hotkeys, replaces the
 * clipboard with synthetic text, saves one fake Memo, and opens/closes its source
 * sheet using keyboard events. Repeated capture runs can create duplicate fake
 * Memos. No clicks, Secret views, credentials, AI requests, or network calls.
 * Results expose only booleans, geometry, and numeric scrollbar values. Record
 * content, field values, and Accessibility labels are never included in output.
 *
 * Limits: no Korean IME composition, undo, or process-restart coverage. A unique
 * query normally has one result, so a nonzero scroll offset needs another test.
 * Successful syntax checking is not evidence that these GUI workflows passed.
 */
ObjC.import('AppKit');

var REVIEW_BUNDLE = 'dev.worklog.UIReview';
var REVIEW_QUERY = 'Maclab UI 회귀 메모 2026-10-10';
var REVIEW_BODY = REVIEW_QUERY + '\n가짜 테스트 기록: 빠른 입력 저장 후 이전 앱으로 돌아옵니다.';

function readSafely(read, fallback) {
    try { return read(); } catch (_) { return fallback; }
}
function option(args, name, fallback) {
    var index = args.indexOf(name);
    return index < 0 || index + 1 >= args.length ? fallback : args[index + 1];
}
function requireState(condition, message) {
    if (!condition) throw new Error(message);
}
function waitFor(read, description, seconds) {
    var deadline = Date.now() + (seconds || 8) * 1000;
    var value;
    do {
        value = readSafely(read, null);
        if (value) return value;
        delay(0.15);
    } while (Date.now() < deadline);
    throw new Error('Timed out: ' + description + '. No application content is included in this diagnostic.');
}
function attribute(element, name, fallback) {
    return readSafely(function () { return element.attributes.byName(name).value(); }, fallback);
}
function role(element) { return readSafely(function () { return element.role(); }, 'unknown'); }
function label(element) {
    // Labels are used only for matching; they are never copied into test output.
    return [attribute(element, 'AXDescription', ''), attribute(element, 'AXTitle', ''),
        readSafely(function () { return element.name(); }, '')]
        .filter(function (value) { return typeof value === 'string'; }).join(' | ');
}
function children(element) { return readSafely(function () { return element.uiElements(); }, []); }
function findElement(root, matches) {
    var queue = [{ element: root, depth: 0 }];
    var inspected = 0;
    while (queue.length && inspected < 750) {
        var item = queue.shift();
        inspected += 1;
        if (matches(item.element)) return item.element;
        if (item.depth < 22) {
            children(item.element).forEach(function (child) {
                queue.push({ element: child, depth: item.depth + 1 });
            });
        }
    }
    return null;
}
function frontmostBundle() {
    return readSafely(function () {
        return ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
    }, null);
}
function worklogProcess(events) {
    var processes = events.processes.whose({ bundleIdentifier: REVIEW_BUNDLE })();
    requireState(processes.length > 0, 'No running dev.worklog.UIReview fixture application. Launch the fake-data build first.');
    // With before/after builds present, prefer the foreground process.
    for (var index = 0; index < processes.length; index += 1) {
        if (readSafely(function () { return processes[index].frontmost(); }, false)) return processes[index];
    }
    requireState(processes.length === 1, 'Multiple review builds are running. Close the other review build before testing.');
    return processes[0];
}
function windows(process) { return readSafely(function () { return process.windows(); }, []); }
function findWindowAndElement(process, matches) {
    var items = windows(process);
    for (var index = 0; index < items.length; index += 1) {
        var element = findElement(items[index], matches);
        if (element) return { window: items[index], element: element };
    }
    return null;
}
function isFocused(element) {
    return attribute(element, 'AXFocused', false) === true || readSafely(function () { return element.focused(); }, false) === true;
}
function textValue(element) {
    var value = attribute(element, 'AXValue', null);
    if (typeof value !== 'string') value = readSafely(function () { return element.value(); }, null);
    return typeof value === 'string' ? value.replace(/\r\n/g, '\n') : null;
}
function putSyntheticText(text) {
    var board = $.NSPasteboard.generalPasteboard;
    board.clearContents;
    requireState(Boolean(board.setStringForType($(text), $.NSPasteboardTypeString)), 'Could not set the synthetic test clipboard.');
}
function paste(events, text, replace) {
    putSyntheticText(text);
    if (replace) events.keystroke('a', { using: ['command down'] });
    events.keystroke('v', { using: ['command down'] });
}
function geometry(element) {
    var position = readSafely(function () { return element.position(); }, null);
    var size = readSafely(function () { return element.size(); }, null);
    if (!position || !size || position.length !== 2 || size.length !== 2) return null;
    return { x: Number(position[0]), y: Number(position[1]), width: Number(size[0]), height: Number(size[1]) };
}
function sameGeometry(first, second) {
    if (!first || !second) return null;
    return ['x', 'y', 'width', 'height'].every(function (key) { return Math.abs(first[key] - second[key]) <= 1; });
}
function captureEditor(element) {
    var text = label(element);
    return role(element) === 'AXTextArea' && (text.indexOf('메모 본문') >= 0 || text.indexOf('무엇을 기록할까요?') >= 0);
}
function searchField(element) {
    return role(element) === 'AXTextField' && label(element).indexOf('원문 검색') >= 0;
}
function sourceSheet(process) {
    var items = windows(process);
    for (var index = 0; index < items.length; index += 1) {
        var sheets = readSafely(function () { return items[index].sheets(); }, []);
        if (sheets.length) return sheets[0];
        var sheet = findElement(items[index], function (element) { return role(element) === 'AXSheet'; });
        if (sheet) return sheet;
    }
    return null;
}
function activateReviewMainWindow(process) {
    var main = windows(process).filter(function (window) {
        return readSafely(function () { return window.subrole(); }, '') === 'AXStandardWindow' &&
            label(window).indexOf('빠른 입력') < 0 && label(window).indexOf('WorkLog 검색') < 0;
    })[0];
    requireState(Boolean(main), 'No main review window is available for the explicit CmdF entry.');
    var running = $.NSRunningApplication.runningApplicationWithProcessIdentifier(process.unixId());
    // NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps.
    running.activateWithOptions(3);
    process.frontmost = true;
    readSafely(function () { main.actions.byName('AXRaise').perform(); return true; }, false);
    readSafely(function () { main.attributes.byName('AXMain').value = true; return true; }, false);
    readSafely(function () { main.attributes.byName('AXFocused').value = true; return true; }, false);
    waitFor(function () {
        return process.frontmost() && (attribute(main, 'AXMain', false) === true || attribute(main, 'AXFocused', false) === true);
    }, 'review main window is activated and raised before CmdF');
    delay(0.2);
}
function searchWindowDiagnostics(process) {
    var items = windows(process);
    return { reviewAppForeground: frontmostBundle() === REVIEW_BUNDLE, windowCount: items.length,
        searchTitledWindowPresent: items.some(function (window) { return label(window).indexOf('WorkLog 검색') >= 0; }),
        searchFieldPresent: Boolean(findWindowAndElement(process, searchField)),
        mainWindowPresent: items.some(function (window) {
            return readSafely(function () { return window.subrole(); }, '') === 'AXStandardWindow';
        }) };
}
function selectedResult(window) {
    return findElement(window, function (element) {
        if (role(element) !== 'AXButton') return false;
        return attribute(element, 'AXValue', '') === '선택됨' || attribute(element, 'AXSelected', false) === true;
    });
}
function scrollbarSnapshot(root) {
    var values = [];
    findElement(root, function (element) {
        if (role(element) === 'AXScrollBar') {
            var value = attribute(element, 'AXValue', null);
            var orientation = attribute(element, 'AXOrientation', 'unknown');
            if (typeof value === 'number' && isFinite(value)) values.push({ orientation: String(orientation), value: value });
        }
        return false;
    });
    return values;
}
function sameScrollbars(first, second) {
    if (!first.length || first.length !== second.length) return null;
    return first.every(function (item, index) {
        return item.orientation === second[index].orientation && Math.abs(item.value - second[index].value) < 0.0001;
    });
}

function run(args) {
    var action = option(args, '--action', null);
    requireState(action === 'capture' || action === 'search', 'Use --action capture or --action search.');
    var events = Application('System Events');
    var process = worklogProcess(events);
    requireState(!sourceSheet(process), 'Close the existing source sheet before running this workflow.');

    if (action === 'capture') {
        requireState(!findWindowAndElement(process, captureEditor), 'A capture draft is already open. Close it without discarding before starting this workflow.');
        Application('TextEdit').activate();
        waitFor(function () { return frontmostBundle() === 'com.apple.TextEdit'; }, 'TextEdit becomes the previous app');
        events.keyCode(49, { using: ['control down', 'option down'] });
        var capture = waitFor(function () { return findWindowAndElement(process, captureEditor); }, 'Memo capture panel opens with a body editor');
        var initialFocus = isFocused(capture.element);
        requireState(initialFocus, 'Memo body did not receive automatic focus on opening; no test text was entered.');
        var original = textValue(capture.element);
        requireState(original === '' || original === REVIEW_BODY, 'Capture contains a different draft; refusing to overwrite it.');
        paste(events, REVIEW_BODY, original !== '');
        waitFor(function () { return textValue(capture.element) === REVIEW_BODY; }, 'synthetic multiline Memo is pasted exactly');
        var beforeFrame = geometry(capture.window);
        events.keyCode(36, { using: ['command down'] });
        waitFor(function () { return !findWindowAndElement(process, captureEditor); }, 'successful save closes the capture panel');
        waitFor(function () { return frontmostBundle() === 'com.apple.TextEdit'; }, 'successful save restores TextEdit');
        return JSON.stringify({ action: action, bundleIdentifier: REVIEW_BUNDLE,
            openedByHotkey: true, memoBodyFocusedOnOpen: initialFocus, exactSyntheticMultilineInput: true,
            captureWindowFrame: beforeFrame, savedAndClosedByCommandReturn: true, previousAppRestored: true,
            limitations: ['This workflow does not simulate Korean marked-text composition.'] }, null, 2);
    }

    var searchEntry = option(args, '--search-open', 'global-hotkey');
    requireState(searchEntry === 'global-hotkey' || searchEntry === 'command-f',
        'Use --search-open global-hotkey or --search-open command-f.');
    if (searchEntry === 'command-f') {
        activateReviewMainWindow(process);
        events.keyCode(3, { using: ['command down'] });
    } else {
        Application('TextEdit').activate();
        waitFor(function () { return frontmostBundle() === 'com.apple.TextEdit'; }, 'TextEdit is active before the global search hotkey');
        events.keyCode(2, { using: ['control down', 'option down'] });
    }
    var search;
    try {
        search = waitFor(function () { return findWindowAndElement(process, searchField); }, 'local search panel opens');
    } catch (_) {
        throw new Error('Search entry failed through ' + searchEntry + ': ' + JSON.stringify(searchWindowDiagnostics(process)));
    }
    var queryFocusedOnOpen = isFocused(search.element);
    requireState(queryFocusedOnOpen, 'Search query did not receive focus; no text was entered.');
    paste(events, REVIEW_QUERY, true);
    waitFor(function () { return textValue(search.element) === REVIEW_QUERY; }, 'synthetic query is pasted exactly');
    // Wait for the debounced local index result, then navigate with the keyboard.
    waitFor(function () {
        return findElement(search.window, function (element) {
            return role(element) === 'AXButton' && label(element).indexOf(REVIEW_QUERY) >= 0;
        });
    }, 'saved synthetic Memo appears in local search results');
    events.keyCode(125);
    var selected = waitFor(function () { return selectedResult(search.window); }, 'Down Arrow selects a local search result');
    var selectionBefore = label(selected);
    requireState(selectionBefore.indexOf(REVIEW_QUERY) >= 0, 'Selected result does not match the synthetic query; refusing to open unrelated content.');
    var rowFrameBefore = geometry(selected);
    var barsBefore = scrollbarSnapshot(search.window);
    var queryBefore = textValue(search.element);
    events.keyCode(36);
    var sheet = waitFor(function () { return sourceSheet(process); }, 'Return opens the saved source sheet');
    var sourceMatches = Boolean(findElement(sheet, function (element) {
        return role(element) === 'AXStaticText' && label(element).indexOf(REVIEW_QUERY) >= 0;
    }));
    requireState(sourceMatches, 'The opened source sheet did not expose the synthetic Memo text through Accessibility.');
    events.keyCode(53);
    waitFor(function () { return !sourceSheet(process); }, 'Escape closes the source and returns to search');
    search = waitFor(function () { return findWindowAndElement(process, searchField); }, 'search query remains available after source closes');
    selected = waitFor(function () { return selectedResult(search.window); }, 'search result remains selected');
    var rowFrameAfter = geometry(selected);
    var barsAfter = scrollbarSnapshot(search.window);
    var queryPreserved = textValue(search.element) === queryBefore && queryBefore === REVIEW_QUERY;
    var selectionPreserved = label(selected) === selectionBefore;
    var rowPositionPreserved = sameGeometry(rowFrameBefore, rowFrameAfter);
    var scrollbarPreserved = sameScrollbars(barsBefore, barsAfter);
    requireState(queryPreserved, 'Search query changed while returning from the source sheet.');
    requireState(selectionPreserved, 'Search result selection changed while returning from the source sheet.');
    requireState(rowPositionPreserved !== false, 'Selected result position shifted while returning from the source sheet.');
    requireState(scrollbarPreserved !== false, 'An exposed scrollbar position changed while returning from the source sheet.');
    return JSON.stringify({ action: action, bundleIdentifier: REVIEW_BUNDLE,
        entryMethod: searchEntry, openedByHotkey: searchEntry === 'global-hotkey',
        queryFocusedOnOpen: queryFocusedOnOpen, savedMemoFoundLocally: true,
        resultSelectedByDownArrow: true, originalOpenedByReturn: true, sourceContainsSyntheticMemo: sourceMatches,
        returnedByEscape: true, queryPreserved: queryPreserved, selectionPreserved: selectionPreserved,
        queryFocusRestored: isFocused(search.element),
        scrollEvidence: { scrollbarBefore: barsBefore, scrollbarAfter: barsAfter,
            exposedScrollbarPositionPreserved: scrollbarPreserved,
            selectedRowFrameBefore: rowFrameBefore, selectedRowFrameAfter: rowFrameAfter,
            selectedRowPositionPreserved: rowPositionPreserved },
        limitations: ['A single matching Memo does not exercise nonzero scroll offsets.',
            'null scrollbar evidence means AppKit did not expose a numeric scrollbar value.',
            'IME composition, undo, and reopening the app are not covered by this workflow.'] }, null, 2);
}
