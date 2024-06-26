//
//  iTermScriptConsole.m
//  iTerm2
//
//  Created by George Nachman on 4/19/18.
//

#import "iTermScriptConsole.h"

#import "iTermAPIServer.h"
#import "iTermScriptHistory.h"
#import "iTermScriptInspector.h"
#import "iTermAPIScriptLauncher.h"
#import "iTermWebSocketConnection.h"
#import "DebugLogging.h"
#import "NSArray+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSTextField+iTerm.h"

typedef NS_ENUM(NSInteger, iTermScriptFilterControlTag) {
    iTermScriptFilterControlTagAll = 0,
    iTermScriptFilterControlTagRunning = 1
};

@interface iTermScriptConsole ()<NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate>

@end

@implementation iTermScriptConsole {
    IBOutlet NSTableView *_tableView;
    IBOutlet NSTabView *_tabView;
    IBOutlet NSTextView *_logsView;
    IBOutlet NSTextView *_callsView;

    IBOutlet NSTableColumn *_nameColumn;
    IBOutlet NSTableColumn *_dateColumn;

    IBOutlet NSSegmentedControl *_scriptFilterControl;

    IBOutlet NSButton *_scrollToBottomOnUpdate;

    NSDateFormatter *_dateFormatter;
    IBOutlet NSTextField *_filter;
    IBOutlet NSButton *_terminateButton;
    IBOutlet NSButton *_startButton;
    iTermScriptInspector *_inspector;

    id _token;
}

+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initWithWindowNibName:@"iTermScriptConsole"];
    });
    return instance;
}

- (void)awakeFromNib {
#ifdef MAC_OS_X_VERSION_10_16
    if (@available(macOS 10.16, *)) {
        _tableView.style = NSTableViewStyleInset;
    }
#endif
    _callsView.textColor = [NSColor textColor];
    NSScrollView *scrollView = _callsView.enclosingScrollView;
    scrollView.horizontalScrollElasticity = NSScrollElasticityNone;
}

- (void)makeTextViewHorizontallyScrollable:(NSTextView *)textView {
    [textView.enclosingScrollView setHasHorizontalScroller:YES];
    [textView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [textView setHorizontallyResizable:YES];
    [[textView textContainer] setWidthTracksTextView:NO];
    [[textView textContainer] setContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
}


- (void)findNext:(id)sender {
    NSControl *fakeSender = [[NSControl alloc] init];
    fakeSender.tag = NSTextFinderActionNextMatch;
    if (_tabView.selectedTabViewItem.view == _logsView.enclosingScrollView) {
        [_logsView performFindPanelAction:fakeSender];
    } else {
        [_callsView performFindPanelAction:fakeSender];
    }
}

- (void)findPrevious:(id)sender {
    NSControl *fakeSender = [[NSControl alloc] init];
    fakeSender.tag = NSTextFinderActionPreviousMatch;
    if (_tabView.selectedTabViewItem.view == _logsView.enclosingScrollView) {
        [_logsView performFindPanelAction:fakeSender];
    } else {
        [_callsView performFindPanelAction:fakeSender];
    }
}

- (IBAction)performFindPanelAction:(id)sender {
    if ([[NSMenuItem castFrom:sender] tag] == NSFindPanelActionShowFindPanel) {
        if (_tabView.selectedTabViewItem.view == _logsView.enclosingScrollView) {
            [_logsView performFindPanelAction:sender];
        } else {
            [_callsView performFindPanelAction:sender];
        }
    }
}

- (instancetype)initWithWindowNibName:(NSNibName)windowNibName {
    self = [super initWithWindowNibName:windowNibName];
    if (self) {
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"Ld jj:mm:ss"
                                                                    options:0
                                                                     locale:[NSLocale currentLocale]];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(numberOfScriptHistoryEntriesDidChange:)
                                                     name:iTermScriptHistoryNumberOfEntriesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(historyEntryDidChange:)
                                                     name:iTermScriptHistoryEntryDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(connectionRejected:)
                                                     name:iTermAPIServerConnectionRejected
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(connectionAccepted:)
                                                     name:iTermAPIServerConnectionAccepted
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(connectionClosed:)
                                                     name:iTermAPIServerConnectionClosed
                                                   object:nil];
    }
    return self;
}

- (void)windowDidLoad {
    [super windowDidLoad];

    _tabView.tabViewItems[0].view = _logsView.enclosingScrollView;
    _tabView.tabViewItems[1].view = _callsView.enclosingScrollView;

    [self makeTextViewHorizontallyScrollable:_logsView];
    [self makeTextViewHorizontallyScrollable:_callsView];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeObserver];
}

- (IBAction)scriptFilterDidChange:(id)sender {
    [_tableView reloadData];
    _terminateButton.enabled = NO;
    _startButton.enabled = NO;
}

- (NSString *)stringForRow:(NSInteger)row column:(NSTableColumn *)column {
    iTermScriptHistoryEntry *entry = [[self filteredEntries] objectAtIndex:row];
    if (column == _nameColumn) {
        if (entry.isRunning) {
            return entry.name;
        } else {
            return [NSString stringWithFormat:@"(%@)", entry.name];
        }
    } else {
        return [_dateFormatter stringFromDate:entry.startDate];
    }
}

- (NSArray<iTermScriptHistoryEntry *> *)filteredEntries {
    if (_scriptFilterControl.selectedSegment == iTermScriptFilterControlTagAll) {
        return [[iTermScriptHistory sharedInstance] entries];
    } else {
        return [[iTermScriptHistory sharedInstance] runningEntries];
    }
}

- (iTermScriptHistoryEntry *)terminateScriptOnRow:(NSInteger)row {
    iTermScriptHistoryEntry *entry = [[self filteredEntries] objectAtIndex:row];
    if (entry.isRunning && entry.onlyPid) {
        [entry kill];
    }
    return entry;
}

- (IBAction)terminate:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row < self.filteredEntries.count) {
        [self terminateScriptOnRow:row];
    }
}

- (IBAction)startOrRestart:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row < self.filteredEntries.count) {
        iTermScriptHistoryEntry *entry = [self terminateScriptOnRow:row];
        if (entry.relaunch) {
            entry.relaunch();
        }
    }
}

- (IBAction)closeCurrentSession:(id)sender {
    [self close];
}

- (void)closeWindow:(id)sender {
    [self close];
}

- (BOOL)autoHidesHotKeyWindow {
    return NO;
}

- (void)cancel:(id)sender {
    [self close];
}

- (IBAction)inspector:(id)sender {
    if (!_inspector) {
        _inspector = [[iTermScriptInspector alloc] initWithWindowNibName:@"iTermScriptInspector"];
    } else {
        [_inspector reload:nil];
    }
    [[_inspector window] makeKeyAndOrderFront:nil];
}

- (void)revealTailOfHistoryEntry:(iTermScriptHistoryEntry *)entry {
    [self.window makeKeyAndOrderFront:nil];

    NSInteger index = [[self filteredEntries] indexOfObject:entry];
    if (index == NSNotFound) {
        index = [[[iTermScriptHistory sharedInstance] entries] indexOfObject:entry];
        if (index != NSNotFound) {
            [_scriptFilterControl selectSegmentWithTag:iTermScriptFilterControlTagAll];
            [_tableView reloadData];
        }
    }
    if (index == NSNotFound) {
        return;
    }
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [_tabView selectFirstTabViewItem:nil];
    [_logsView scrollToEndOfDocument:nil];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [[self filteredEntries] count];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    static NSString *const identifier = @"ScriptConsoleEntryIdentifier";
    NSTextField *result = [tableView makeViewWithIdentifier:identifier owner:self];
    if (result == nil) {
        result = [NSTextField it_textFieldForTableViewWithIdentifier:identifier];
        result.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    }

    id value = [self stringForRow:row column:tableColumn];
    if ([value isKindOfClass:[NSAttributedString class]]) {
        result.attributedStringValue = value;
        result.toolTip = [value string];
    } else {
        result.stringValue = value;
        result.toolTip = value;
    }

    return result;
}

#pragma mark - NSTabViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self removeObserver];
    if (!_tableView.numberOfSelectedRows) {
        _logsView.string = @"";
        _callsView.string = @"";
        _terminateButton.enabled = NO;
        _startButton.enabled = NO;
    } else {
        [self scrollLogsToBottomIfNeeded];
        [self scrollCallsToBottomIfNeeded];
        NSInteger row = _tableView.selectedRow;
        iTermScriptHistoryEntry *entry = [[self filteredEntries] objectAtIndex:row];
        _terminateButton.enabled = entry.isRunning && (entry.onlyPid != 0);
        _startButton.enabled = entry.relaunch != nil;
        _logsView.font = [NSFont fontWithName:@"Menlo" size:12];
        _callsView.font = [NSFont fontWithName:@"Menlo" size:12];

        _logsView.string = [entry.logLines componentsJoinedByString:@"\n"];
        if (!entry.lastLogLineContinues) {
            _logsView.string = [_logsView.string stringByAppendingString:@"\n"];
        }
        _callsView.string = [entry.callEntries componentsJoinedByString:@"\n"];
        __weak __typeof(self) weakSelf = self;
        _token = [[NSNotificationCenter defaultCenter] addObserverForName:iTermScriptHistoryEntryDidChangeNotification
                                                                   object:entry
                                                                    queue:nil
                                                               usingBlock:^(NSNotification * _Nonnull note) {
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (note.userInfo) {
                NSString *delta = note.userInfo[iTermScriptHistoryEntryDelta];
                NSString *property = note.userInfo[iTermScriptHistoryEntryFieldKey];
                if ([property isEqualToString:iTermScriptHistoryEntryFieldLogsValue]) {
                    [strongSelf appendLogs:delta];
                    [strongSelf scrollLogsToBottomIfNeeded];
                } else if ([property isEqualToString:iTermScriptHistoryEntryFieldRPCValue]) {
                    [strongSelf appendCalls:delta];
                    [strongSelf scrollCallsToBottomIfNeeded];
                }
            } else {
                [strongSelf->_tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                                  columnIndexes:[NSIndexSet indexSetWithIndex:0]];
            }
        }];
    }
}

- (void)appendLogs:(NSString *)delta {
    if (!_filter.stringValue.length) {
        [_logsView.textStorage.mutableString appendString:delta];
    } else {
        [self updateFilteredValue];
    }
}

- (void)appendCalls:(NSString *)delta {
    if (!_filter.stringValue.length) {
        [_callsView.textStorage.mutableString appendString:delta];
    } else {
        [self updateFilteredValue];
    }
}

- (void)scrollLogsToBottomIfNeeded {
    if (_scrollToBottomOnUpdate.state == NSControlStateValueOn && _tabView.selectedTabViewItem.view == _logsView.enclosingScrollView) {
        [_logsView scrollRangeToVisible: NSMakeRange(_logsView.string.length, 0)];
    }
}

- (void)scrollCallsToBottomIfNeeded {
    if (_scrollToBottomOnUpdate.state == NSControlStateValueOn && _tabView.selectedTabViewItem.view == _callsView.enclosingScrollView) {
        [_callsView scrollRangeToVisible: NSMakeRange(_callsView.string.length, 0)];
    }
}

- (IBAction)filterDidChange:(id)sender {
    [self updateFilteredValue];
}

- (BOOL)line:(NSString *)line containsString:(NSString *)filter caseSensitive:(BOOL)caseSensitive {
    if (caseSensitive) {
        return [line containsString:filter];
    } else {
        return [line localizedCaseInsensitiveContainsString:filter];
    }
}

- (void)updateFilteredValue {
    if (_tableView.selectedRow == -1) {
        _logsView.string = @"";
        _callsView.string = @"";
        return;
    }
    iTermScriptHistoryEntry *entry = [[self filteredEntries] objectAtIndex:_tableView.selectedRow];

    NSString *filter = _filter.stringValue;
    BOOL unfiltered = filter.length == 0;
    BOOL caseSensitive = [filter rangeOfCharacterFromSet:[NSCharacterSet uppercaseLetterCharacterSet]].location != NSNotFound;
    NSString *newValue = [[entry.logLines filteredArrayUsingBlock:^BOOL(NSString *line) {
        return unfiltered || [self line:line containsString:filter caseSensitive:caseSensitive];
    }] componentsJoinedByString:@"\n"];
    _logsView.string = newValue;

    newValue = [[entry.callEntries filteredArrayUsingBlock:^BOOL(NSString *line) {
        return unfiltered || [self line:line containsString:filter caseSensitive:caseSensitive];
    }] componentsJoinedByString:@"\n"];
    _callsView.string = newValue;
}

- (void)controlTextDidChange:(NSNotification *)aNotification {
    [self updateFilteredValue];
}

#pragma mark - Notifications

- (void)numberOfScriptHistoryEntriesDidChange:(NSNotification *)notification {
    [_tableView reloadData];
    _terminateButton.enabled = NO;
    _startButton.enabled = NO;
}

- (void)historyEntryDidChange:(NSNotification *)notification {
    if (!notification.userInfo) {
        [_tableView reloadData];
        _terminateButton.enabled = NO;
        _startButton.enabled = NO;
    }
}

- (NSString *)formatPIDs:(NSArray<NSNumber *> *)pids {
    if (pids.count == 1) {
        return [NSString stringWithFormat:@"PID %@", pids[0]];
    }
    return [NSString stringWithFormat:@"PIDs %@", [pids componentsJoinedByString:@", "]];
}

- (void)connectionRejected:(NSNotification *)notification {
    NSString *key = notification.object;
    iTermScriptHistoryEntry *entry = nil;
    if (key) {
        entry = [[iTermScriptHistory sharedInstance] entryWithIdentifier:key];
    } else {
        key = [[NSUUID UUID] UUIDString];  // Just needs to be something unique to identify this now-immutable log
    }
    if (!entry) {
        NSString *name = [NSString castFrom:notification.userInfo[@"job"]];
        if (!name) {
            name = [self formatPIDs:notification.userInfo[@"pids"]];
        }
        if (!name) {
            // Shouldn't happen as there ought to always be a PID
            name = @"Unknown";
        }
        entry = [[iTermScriptHistoryEntry alloc] initWithName:name
                                                     fullPath:nil
                                                   identifier:key
                                                     relaunch:nil];
    }
    entry.pids = notification.userInfo[@"pids"];
    [[iTermScriptHistory sharedInstance] addHistoryEntry:entry];
    [entry addOutput:notification.userInfo[@"reason"] completion:^{}];
    [entry stopRunning];
}

- (void)connectionAccepted:(NSNotification *)notification {
    NSString *key = notification.object;
    DLog(@"Connection accepted with key %@", key);
    iTermScriptHistoryEntry *entry = nil;
    if (key) {
        entry = [[iTermScriptHistory sharedInstance] entryWithIdentifier:key];
    } else {
        assert(false);
    }
    if (!entry) {
        NSString *name = [NSString castFrom:notification.userInfo[@"job"]];
        if (!name) {
            name = [self formatPIDs:notification.userInfo[@"pids"]];
        }
        if (!name) {
            // Shouldn't happen as there ought to always be a PID
            name = @"Unknown";
        }
        entry = [[iTermScriptHistoryEntry alloc] initWithName:name
                                                     fullPath:nil
                                                   identifier:key
                                                     relaunch:nil];
        entry.pids = notification.userInfo[@"pids"];
        DLog(@"Add history entry");
        [[iTermScriptHistory sharedInstance] addHistoryEntry:entry];
    }
    entry.websocketConnection = notification.userInfo[@"websocket"];
    DLog(@"Adding output");
    [entry addOutput:[NSString stringWithFormat:@"Connection accepted: %@\n", notification.userInfo[@"reason"]]
          completion:^{}];
    DLog(@"Done");
}

- (void)connectionClosed:(NSNotification *)notification {
    NSString *key = notification.object;
    assert(key);
    iTermScriptHistoryEntry *entry = [[iTermScriptHistory sharedInstance] entryWithIdentifier:key];
    if (!entry) {
        return;
    }
    [entry addOutput:@"\nConnection closed.\n" completion:^{}];
    [entry stopRunning];
}

#pragma mark - Private

- (void)removeObserver {
    if (_token) {
        [[NSNotificationCenter defaultCenter] removeObserver:_token];
        _token = nil;
    }
}

@end
