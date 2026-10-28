/* Native diagnostics UI verification for dev.worklog.UIReview DEBUG many fixture only.
 * osascript -l JavaScript scripts/maclab/diagnostics-ui-check.js --action inspect|export|delete
 * Verifies the actual launch arguments and DiagnosticsReview.app path before input.
 * Exports a synthetic report only to a new /tmp path; deletes only fixture diagnostics.
 * No user credentials, microphone, network, settings save, or user record mutation.
 * Captures only the owned fixture window. Run caffeinate -u -t 5 before UI work.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

function reviewRead(node, attribute) {
    if (!node) return null;
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function reviewString(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value);
    return typeof result === 'string' ? result : '';
}
function reviewText(node, attribute) { return reviewString(reviewRead(node, attribute)); }
function reviewArray(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    return result;
}

function run(args) {
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var result = { ok: false, checks: {}, credentialsUsed: false, recordingUsed: false, settingsSaved: false };
    var stage = 'fixture_guard', appAX, reviewPID, running, events, root;
    function fail(code) { var error = new Error(code); error.reviewCode = code; throw error; }
    function need(value, code) { if (!value) fail(code); return value; }
    function check(name, value) { result.checks[name] = Boolean(value); need(value, 'ASSERTION_' + name); }
    function tick() {
        need(Number($.NSProcessInfo.processInfo.systemUptime) - started < 55, 'WORKFLOW_DEADLINE');
    }
    function pause() { tick(); delay(0.15); }
    function waitFor(read, code) {
        var until = Number($.NSProcessInfo.processInfo.systemUptime) + 5;
        do {
            tick();
            var value = read();
            if (value) return value;
            delay(0.12);
        } while (Number($.NSProcessInfo.processInfo.systemUptime) < until);
        fail(code);
    }
    function windows() { return reviewArray(reviewRead(appAX, 'AXWindows')); }
    function windowNamed(title) {
        return windows().filter(function (node) { return reviewText(node, 'AXTitle') === title; })[0] || null;
    }
    function walk(container, visit) {
        var queue = [{ node: container, depth: 0 }], count = 0;
        while (queue.length && count++ < 1400) {
            tick();
            var item = queue.shift(), role = reviewText(item.node, 'AXRole');
            if (visit(item.node, role)) return item.node;
            if (item.depth < 28) reviewArray(reviewRead(item.node, 'AXChildren')).forEach(function (child) {
                queue.push({ node: child, depth: item.depth + 1 });
            });
        }
        need(queue.length === 0, 'AX_TRAVERSAL_LIMIT');
        return null;
    }
    function find(role, text, exact) {
        var candidates = windows();
        candidates.slice().forEach(function (window) { candidates = candidates.concat(reviewArray(reviewRead(window, 'AXSheets'))); });
        for (var container of candidates) {
        var found = walk(container, function (node, actualRole) {
            if (role && role !== actualRole) return false;
            var labels = [reviewText(node, 'AXTitle'), reviewText(node, 'AXDescription'), reviewText(node, 'AXIdentifier')];
            if (actualRole === 'AXStaticText') labels.push(reviewText(node, 'AXValue'));
            return labels.some(function (label) {
                return exact ? label === text : label.indexOf(text) >= 0;
            });
        });
        if (found) return found;
        }
        return null;
    }
    function control(role, text, exact) { return need(find(role, text, exact), 'CONTROL_MISSING'); }
    function front() {
        return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
    }
    function press(node) {
        need(front(), 'LOST_FOREGROUND');
        need(Number($.AXUIElementPerformAction(node, $('AXPress'))) === 0, 'AX_PRESS_FAILED');
        pause();
    }
    function key(code, modifiers) {
        need(front(), 'LOST_FOREGROUND');
        events.keyCode(code, { using: modifiers || [] });
        pause();
    }
    function clickField(node) {
        // SwiftUI plain fields can acknowledge AXFocused without becoming the
        // text responder. Click the actual AX bounds to use native hit testing.
        function coordinate(attribute, component) {
            var nativeValue = need(reviewRead(node, attribute), 'FIELD_BOUNDS_MISSING');
            var description = reviewString(ObjC.castRefToObject($.CFCopyDescription(nativeValue)));
            var names = component === 'width' ? '(?:width|w)' : component === 'height' ? '(?:height|h)' : component;
            var match = description.match(new RegExp('\\b' + names + '\\s*[:=]\\s*(-?[0-9]+(?:\\.[0-9]+)?)'));
            need(match, 'FIELD_BOUNDS_UNREADABLE');
            return Number(match[1]);
        }
        var x = coordinate('AXPosition', 'x'), y = coordinate('AXPosition', 'y');
        var width = coordinate('AXSize', 'width'), height = coordinate('AXSize', 'height');
        need(width > 0 && height > 0, 'FIELD_BOUNDS_EMPTY');
        var point = $.CGPointMake(x + width / 2, y + height / 2);
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
        pause();
    }
    function input(fieldLabel, value) {
        need(front(), 'LOST_FOREGROUND');
        // SwiftUI can replace AX proxies when navigation or search rerenders.
        // Resolve by the stable label both before input and on each value check.
        var node = control('AXTextField', fieldLabel, true);
        clickField(node);
        key(0, ['command down']);
        if (value) {
            var clipboard = $.NSPasteboard.generalPasteboard;
            clipboard.clearContents;
            need(clipboard.setStringForType($(value), $.NSPasteboardTypeString), 'PASTE_FAILED');
            key(9, ['command down']);
        } else key(51);
        waitFor(function () {
            var current = find('AXTextField', fieldLabel, true);
            return current && reviewText(current, 'AXValue') === value;
        }, 'SEARCH_TEXT_NOT_ENTERED');
    }

    function paste(value) {
        var clipboard = $.NSPasteboard.generalPasteboard;
        clipboard.clearContents;
        need(clipboard.setStringForType($(value), $.NSPasteboardTypeString), 'PASTE_FAILED');
        key(9, ['command down']);
    }
    function capture() {
        var info = reviewArray(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
        var owned = info.filter(function (item) {
            var bounds = ObjC.deepUnwrap(item.objectForKey('kCGWindowBounds'));
            return Number(ObjC.unwrap(item.objectForKey('kCGWindowOwnerPID'))) === reviewPID && bounds.Width >= 500 && bounds.Height >= 300;
        });
        need(owned.length === 1, 'SINGLE_FIXTURE_CAPTURE_REQUIRED');
        var id = Number(ObjC.unwrap(owned[0].objectForKey('kCGWindowNumber')));
        var path = '/tmp/worklog-diagnostics-review-' + reviewPID + '.png';
        try {
            automation.doShellScript('/usr/sbin/screencapture -x -o -l ' + id + ' ' + path);
            result.screenshot = path;
        } catch (_) { result.screenshotUnavailable = true; }
    }
    try {
        need(args.length === 2 && args[0] === '--action' && ['inspect', 'export', 'delete'].indexOf(args[1]) >= 0, 'ARGUMENTS');
        result.action = args[1];
        var apps = reviewArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return reviewString(app.bundleIdentifier) === 'dev.worklog.UIReview';
        });
        need(apps.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        running = apps[0]; reviewPID = Number(running.processIdentifier);
        need(isFinite(reviewPID) && reviewPID > 1 && Math.floor(reviewPID) === reviewPID, 'INVALID_REVIEW_PID');
        need(/\/\.build\/DiagnosticsReview\.app$/.test(reviewString(running.bundleURL.path)), 'REVIEW_BUNDLE_PATH');
        var automation = Application.currentApplication(); automation.includeStandardAdditions = true;
        var launch = automation.doShellScript('/bin/ps -ww -p ' + reviewPID + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+many(?:\s|$)/.test(launch), 'REVIEW_LAUNCH_NOT_MANY_FIXTURE');
        need((launch.match(/--ui-test-fixture/g) || []).length === 1, 'AMBIGUOUS_FIXTURE_ARGUMENTS');
        launch = null; check('actualManyFixtureLaunchVerified', true);
        var session = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary()));
        need(!session.CGSSessionScreenIsLocked && session.kCGSSessionOnConsoleKey && session.kCGSessionLoginDoneKey, 'CONSOLE_UNAVAILABLE');
        need(Boolean($.AXIsProcessTrusted()), 'ACCESSIBILITY_UNAVAILABLE');
        appAX = $.AXUIElementCreateApplication(reviewPID); $.AXUIElementSetMessagingTimeout(appAX, 0.5);
        running.activateWithOptions(3); waitFor(front, 'APP_NOT_ACTIVE');
        var main = waitFor(function () { return windows().filter(function (node) { return reviewText(node, 'AXSubrole') === 'AXStandardWindow'; })[0]; }, 'MAIN_WINDOW_MISSING');
        root = main; events = Application('System Events');
        need(!reviewArray(reviewRead(root, 'AXSheets')).length, 'CLOSE_EXISTING_SHEET');
        $.AXUIElementPerformAction(root, $('AXRaise'));
        stage = 'navigate'; key(43, ['command down']);
        waitFor(function () { return find('AXTextField', '설정 항목 검색', true); }, 'SETTINGS_SEARCH_MISSING');
        input('설정 항목 검색', '진단');
        var navigation = waitFor(function () { return find(null, '진단 로그', true); }, 'DIAGNOSTICS_NAVIGATION_MISSING');
        clickField(navigation);
        var exportButton = waitFor(function () { return find('AXButton', 'diagnostics.export', true); }, 'DIAGNOSTICS_CONTENT_MISSING');
        check('retentionVisible', find('AXStaticText', '최근 7일 · 최대 10 MB', true) !== null);
        check('privacyNoticeVisible', find('AXStaticText', '메모·회의 내용·음성·Secret·토큰·계정·파일 경로는 포함하지 않습니다.') !== null);
        check('noAutomaticUploadNotice', find('AXStaticText', '자동 전송하지 않습니다.') !== null);
        check('deleteControlVisible', find('AXButton', 'diagnostics.delete', true) !== null);
        if (result.action === 'export') {
            stage = 'keyboard_export';
            clickField(control('AXTextField', '설정 항목 검색', true));
            var exportFocused = false;
            for (var tabIndex = 0; tabIndex < 28; tabIndex++) {
                key(48);
                var focused = reviewRead(appAX, 'AXFocusedUIElement');
                if (reviewText(focused, 'AXIdentifier') === 'diagnostics.export') { exportFocused = true; break; }
            }
            check('exportReachableByTab', exportFocused);
            key(36);
            waitFor(function () { return find('AXButton', '저장', true) || find('AXButton', 'Save', true); }, 'SAVE_PANEL_MISSING');
            check('keyboardOpensSavePanel', true);
            var nameField = find('AXTextField', 'saveAsNameTextField', true);
            need(nameField, 'SAVE_NAME_FIELD_MISSING');
            var basename = 'worklog-diagnostics-review-' + reviewPID + '-' + Math.floor(Number($.NSProcessInfo.processInfo.systemUptime)) + '.json';
            var output = '/tmp/' + basename;
            need(!$.NSFileManager.defaultManager.fileExistsAtPath($(output)), 'EXPORT_FILE_ALREADY_EXISTS');
            clickField(nameField); key(0, ['command down']); paste(basename);
            stage = 'save_location';
            key(5, ['command down', 'shift down']);
            var pathField = waitFor(function () { return find('AXTextField', 'PathTextField', true); }, 'GO_TO_PATH_MISSING');
            clickField(pathField); key(0, ['command down']); paste('/private/tmp');
            waitFor(function () { return reviewText(find('AXTextField', 'PathTextField', true), 'AXValue') === '/private/tmp'; }, 'GO_TO_PATH_NOT_ENTERED');
            key(36);
            waitFor(function () { return find('AXTextField', 'PathTextField', true) === null; }, 'GO_TO_PATH_NOT_COMMITTED');
            stage = 'save_report';
            press(need(find('AXButton', '저장', true) || find('AXButton', 'Save', true), 'SAVE_BUTTON_MISSING'));
            waitFor(function () { return $.NSFileManager.defaultManager.fileExistsAtPath($(output)); }, 'EXPORT_FILE_MISSING');
            var data = reviewString($.NSString.stringWithContentsOfFileEncodingError($(output), $.NSUTF8StringEncoding, null));
            var report = JSON.parse(data);
            check('validReportJSON', report.schemaVersion === 1 && Array.isArray(report.events));
            check('reportContainsActivity', report.events.length > 0);
            check('retentionInReport', report.retentionDays === 7);
            check('savedFeedbackVisible', find('AXStaticText', '진단 리포트를 저장했습니다.') !== null);
            result.report = output; result.eventCount = report.events.length;
            data = null; report = null;
        } else if (result.action === 'delete') {
            stage = 'delete_cancel';
            clickField(control('AXTextField', '설정 항목 검색', true));
            var deleteFocused = false;
            for (var deleteTab = 0; deleteTab < 20; deleteTab++) {
                key(48);
                if (reviewText(reviewRead(appAX, 'AXFocusedUIElement'), 'AXIdentifier') === 'diagnostics.delete') { deleteFocused = true; break; }
            }
            check('deleteReachableByTab', deleteFocused); key(49);
            waitFor(function () { return find(null, '저장된 진단 로그를 삭제할까요?', true); }, 'DELETE_CONFIRMATION_MISSING');
            key(53);
            check('deleteCancellation', find(null, '저장된 진단 로그를 삭제할까요?', true) === null);
            stage = 'delete_confirm'; clickField(control('AXButton', 'diagnostics.delete', true));
            waitFor(function () { return find(null, '저장된 진단 로그를 삭제할까요?', true); }, 'DELETE_CONFIRMATION_MISSING');
            var confirm = null;
            for (var window of windows()) {
                confirm = walk(window, function(node, role) { return role === 'AXButton' && reviewText(node, 'AXIdentifier') !== 'diagnostics.delete' && [reviewText(node, 'AXTitle'), reviewText(node, 'AXDescription')].indexOf('로그 삭제') >= 0; });
                if (confirm) break;
            }
            clickField(need(confirm, 'DELETE_BUTTON_MISSING'));
            waitFor(function () { return find('AXStaticText', '저장된 진단 로그를 삭제했습니다.', true); }, 'DELETE_FEEDBACK_MISSING');
            check('fixtureLogsDeleted', true);
            check('zeroEventsAfterDeletion', find('AXStaticText', '0개', true) !== null);
        }
        capture(); result.ok = true; stage = 'complete';
    } catch (error) {
        result.failureStage = stage; result.errorCode = error.reviewCode || 'AX_OR_AUTOMATION_FAILURE';
    }
    result.stage = stage;
    if (!result.ok) throw new Error(JSON.stringify(result));
    return JSON.stringify(result);
}
