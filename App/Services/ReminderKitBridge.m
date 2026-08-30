#import "ReminderKitBridge.h"

#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const IMCPReminderKitErrorDomain = @"IMCPReminderKitError";

typedef NS_ENUM(NSInteger, IMCPReminderKitErrorCode) {
    IMCPReminderKitErrorUnavailable = 1,
    IMCPReminderKitErrorBadIdentifier = 2,
    IMCPReminderKitErrorMissingSelector = 3,
    IMCPReminderKitErrorNotFound = 4,
    IMCPReminderKitErrorSaveFailed = 5,
    IMCPReminderKitErrorNoAccount = 6,
};

#pragma mark - Private selector declarations

/// Declares every private selector this file sends, so the compiler knows their
/// signatures. It is deliberately never implemented and never referenced as a
/// class — only used as a cast target — so no `ReminderKit` symbol is ever
/// emitted and the app links without the private framework.
@interface IMCPREMShim : NSObject

// REMObjectID — `objectIDWithURL:` is a class method, sent to the Class object.
- (id)objectIDWithURL:(NSURL *)url;
- (NSUUID *)uuid;

// REMStore
- (NSArray *)fetchListSectionsWithListObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchTemplateWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchPrimaryActiveCloudKitAccountWithError:(NSError **)error;
- (id)fetchDefaultAccountWithError:(NSError **)error;

// REMSaveRequest
- (instancetype)initWithStore:(id)store;
- (id)updateAccount:(id)account;
- (id)updateList:(id)list;
- (id)updateListSection:(id)section;
- (id)updateTemplate:(id)templateObject;
- (id)addListSectionWithDisplayName:(NSString *)name
     toListSectionContextChangeItem:(id)context;
- (id)addTemplateWithName:(NSString *)name
            configuration:(id)configuration
      toAccountChangeItem:(id)accountChangeItem;
- (id)addListUsingTemplate:(id)templateObject toAccountChangeItem:(id)accountChangeItem;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;

// REMAccount / REMAccountTemplatesContext
- (id)templatesContext;
- (NSArray *)fetchTemplatesWithError:(NSError **)error;

// Stored objects (these forward to their backing storage at runtime)
- (NSString *)displayName;
- (NSString *)name;

// Change items
- (id)remObjectID;
- (id)sectionsContextChangeItem;
- (void)setDisplayName:(NSString *)displayName;
- (void)setName:(NSString *)name;
- (void)removeFromList;
- (void)removeFromParentAccount;
- (void)setShouldUpdateSectionsOrdering:(BOOL)update;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (void)setUnsavedSectionIDsOrdering:(NSArray *)ordering;

// REMTemplateConfiguration
- (instancetype)initWithSourceListID:(id)sourceListID
                 shouldSaveCompleted:(BOOL)shouldSaveCompleted;

// REMMembership / REMMemberships
- (instancetype)initWithMemberIdentifier:(NSUUID *)memberIdentifier
                         groupIdentifier:(NSUUID *)groupIdentifier
                              isObsolete:(BOOL)isObsolete
                              modifiedOn:(NSDate *)modifiedOn;
- (instancetype)initWithMemberships:(NSArray *)memberships;

@end

#pragma mark - Helpers

static BOOL IMCPFail(NSError **error, IMCPReminderKitErrorCode code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:IMCPReminderKitErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
    }
    return NO;
}

/// Loads ReminderKit once, without linking against it.
static BOOL IMCPLoadReminderKit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"REMStore") == nil) {
            dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
                   RTLD_LAZY);
        }
    });

    return NSClassFromString(@"REMStore") != nil
        && NSClassFromString(@"REMObjectID") != nil
        && NSClassFromString(@"REMSaveRequest") != nil;
}

static BOOL IMCPRequireAvailable(NSError **error) {
    if (IMCPLoadReminderKit()) { return YES; }
    return IMCPFail(error, IMCPReminderKitErrorUnavailable,
                    @"Apple's private ReminderKit framework could not be loaded, so Reminders "
                     "sections and templates can't be modified on this system.");
}

/// Sends nothing until the receiver proves it implements the selector.
static BOOL IMCPRequireSelector(id object, SEL selector, NSError **error) {
    if (object != nil && [object respondsToSelector:selector]) { return YES; }
    return IMCPFail(error, IMCPReminderKitErrorMissingSelector,
                    [NSString stringWithFormat:
                        @"Apple's private ReminderKit API no longer responds to -%@. This most "
                         "likely means a macOS update changed it; Reminders section and template "
                         "editing in iMCP needs to be updated.",
                        NSStringFromSelector(selector)]);
}

/// Builds a `REMObjectID` for one entity, refusing anything that isn't a UUID.
static id IMCPObjectID(NSString *entity, NSString *identifier, NSError **error) {
    if (![identifier isKindOfClass:[NSString class]]
        || [[NSUUID alloc] initWithUUIDString:identifier] == nil) {
        IMCPFail(error, IMCPReminderKitErrorBadIdentifier,
                 [NSString stringWithFormat:@"\"%@\" is not a valid Reminders identifier",
                                            identifier ?: @"(null)"]);
        return nil;
    }

    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"x-apple-reminderkit://%@/%@", entity, identifier]];
    if (url == nil) {
        IMCPFail(error, IMCPReminderKitErrorBadIdentifier,
                 @"Could not build a Reminders object URL");
        return nil;
    }

    Class objectIDClass = NSClassFromString(@"REMObjectID");
    if (!IMCPRequireSelector(objectIDClass, @selector(objectIDWithURL:), error)) { return nil; }

    id objectID = [(IMCPREMShim *)objectIDClass objectIDWithURL:url];
    if (objectID == nil) {
        IMCPFail(error, IMCPReminderKitErrorBadIdentifier,
                 [NSString stringWithFormat:@"Reminders rejected the identifier %@", identifier]);
    }
    return objectID;
}

static id IMCPMakeStore(NSError **error) {
    id store = [[NSClassFromString(@"REMStore") alloc] init];
    if (store == nil) {
        IMCPFail(error, IMCPReminderKitErrorUnavailable, @"Could not open the Reminders store");
    }
    return store;
}

static id IMCPMakeSaveRequest(id store, NSError **error) {
    id request = [NSClassFromString(@"REMSaveRequest") alloc];
    if (!IMCPRequireSelector(request, @selector(initWithStore:), error)) { return nil; }

    id saveRequest = [(IMCPREMShim *)request initWithStore:store];
    if (saveRequest == nil) {
        IMCPFail(error, IMCPReminderKitErrorUnavailable,
                 @"Could not start a Reminders save request");
    }
    return saveRequest;
}

static BOOL IMCPSave(id saveRequest, NSString *what, NSError **error) {
    if (!IMCPRequireSelector(saveRequest, @selector(saveSynchronouslyWithError:), error)) {
        return NO;
    }

    NSError *saveError = nil;
    if ([(IMCPREMShim *)saveRequest saveSynchronouslyWithError:&saveError]) { return YES; }

    return IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                    [NSString stringWithFormat:@"Reminders could not %@: %@", what,
                        saveError.localizedDescription ?: @"the change was rejected"]);
}

/// Fetches an object by identifier, reporting a readable error when it's missing.
static id IMCPFetch(id store, SEL fetchSelector, NSString *entity, NSString *identifier,
                    NSString *label, NSError **error) {
    id objectID = IMCPObjectID(entity, identifier, error);
    if (objectID == nil) { return nil; }
    if (!IMCPRequireSelector(store, fetchSelector, error)) { return nil; }

    NSError *fetchError = nil;
    id object = nil;
    if (fetchSelector == @selector(fetchListWithObjectID:error:)) {
        object = [(IMCPREMShim *)store fetchListWithObjectID:objectID error:&fetchError];
    } else if (fetchSelector == @selector(fetchListSectionWithObjectID:error:)) {
        object = [(IMCPREMShim *)store fetchListSectionWithObjectID:objectID error:&fetchError];
    } else if (fetchSelector == @selector(fetchReminderWithObjectID:error:)) {
        object = [(IMCPREMShim *)store fetchReminderWithObjectID:objectID error:&fetchError];
    } else if (fetchSelector == @selector(fetchTemplateWithObjectID:error:)) {
        object = [(IMCPREMShim *)store fetchTemplateWithObjectID:objectID error:&fetchError];
    }

    if (object == nil) {
        IMCPFail(error, IMCPReminderKitErrorNotFound,
                 [NSString stringWithFormat:@"No %@ with identifier %@ (%@)", label, identifier,
                     fetchError.localizedDescription ?: @"not found"]);
    }
    return object;
}

/// The account new templates and template-derived lists belong to.
///
/// RemCTL additionally requires the class name to contain "CloudKit"; that check
/// is wrong here — `fetchPrimaryActiveCloudKitAccountWithError:` returns a plain
/// `REMAccount` on current macOS, and rejecting it would block a perfectly good
/// account. The successful primary fetch is the gate.
static id IMCPPrimaryAccount(id store, NSError **error) {
    NSError *accountError = nil;
    id account = nil;

    if ([store respondsToSelector:@selector(fetchPrimaryActiveCloudKitAccountWithError:)]) {
        account = [(IMCPREMShim *)store fetchPrimaryActiveCloudKitAccountWithError:&accountError];
    }
    if (account == nil
        && [store respondsToSelector:@selector(fetchDefaultAccountWithError:)]) {
        accountError = nil;
        account = [(IMCPREMShim *)store fetchDefaultAccountWithError:&accountError];
    }

    if (account == nil) {
        IMCPFail(error, IMCPReminderKitErrorNoAccount,
                 [NSString stringWithFormat:@"No Reminders account is available (%@)",
                     accountError.localizedDescription ?: @"none found"]);
    }
    return account;
}

#pragma mark - IMCPReminderKit

@implementation IMCPReminderKit

+ (BOOL)isAvailable {
    return IMCPLoadReminderKit();
}

/// Turns fetched ReminderKit objects into plain name/identifier pairs.
///
/// `REMListSection` and `REMTemplate` forward unknown selectors to their backing
/// storage, so their name accessors don't appear in the class's own method list
/// but do answer `-respondsToSelector:`. Anything that can't produce both a name
/// and an identifier is skipped rather than guessed at.
static NSArray<NSDictionary<NSString *, NSString *> *> *IMCPDescribe(NSArray *objects,
                                                                    SEL nameSelector) {
    NSMutableArray *described = [NSMutableArray array];
    for (id object in objects) {
        if (![object respondsToSelector:nameSelector]
            || ![object respondsToSelector:@selector(remObjectID)]) {
            continue;
        }

        NSString *name = (nameSelector == @selector(displayName))
            ? [(IMCPREMShim *)object displayName]
            : [(IMCPREMShim *)object name];
        id objectID = [(IMCPREMShim *)object remObjectID];
        if (![objectID respondsToSelector:@selector(uuid)]) { continue; }

        NSString *identifier = [(IMCPREMShim *)objectID uuid].UUIDString;
        if (name == nil || identifier == nil) { continue; }
        [described addObject:@{@"name": name, @"identifier": identifier}];
    }
    return described;
}

+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)
    sectionsInListWithIdentifier:(NSString *)listIdentifier
                           error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return nil; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return nil; }

    id listObjectID = IMCPObjectID(@"REMCDList", listIdentifier, error);
    if (listObjectID == nil) { return nil; }

    if (!IMCPRequireSelector(store, @selector(fetchListSectionsWithListObjectID:error:), error)) {
        return nil;
    }

    NSError *fetchError = nil;
    NSArray *sections = [(IMCPREMShim *)store fetchListSectionsWithListObjectID:listObjectID
                                                                          error:&fetchError];
    if (sections == nil) {
        IMCPFail(error, IMCPReminderKitErrorNotFound,
                 [NSString stringWithFormat:@"Could not read the sections of list %@ (%@)",
                     listIdentifier, fetchError.localizedDescription ?: @"not found"]);
        return nil;
    }

    return IMCPDescribe(sections, @selector(displayName));
}

+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)templatesWithError:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return nil; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return nil; }

    id account = IMCPPrimaryAccount(store, error);
    if (account == nil) { return nil; }

    if (!IMCPRequireSelector(account, @selector(templatesContext), error)) { return nil; }
    id templatesContext = [(IMCPREMShim *)account templatesContext];
    if (!IMCPRequireSelector(templatesContext, @selector(fetchTemplatesWithError:), error)) {
        return nil;
    }

    NSError *fetchError = nil;
    NSArray *templates = [(IMCPREMShim *)templatesContext fetchTemplatesWithError:&fetchError];
    if (templates == nil) {
        IMCPFail(error, IMCPReminderKitErrorNotFound,
                 [NSString stringWithFormat:@"Could not read saved templates (%@)",
                     fetchError.localizedDescription ?: @"none found"]);
        return nil;
    }

    return IMCPDescribe(templates, @selector(name));
}

+ (nullable NSString *)createSectionInListWithIdentifier:(NSString *)listIdentifier
                              existingSectionIdentifiers:(NSArray<NSString *> *)existingSectionIdentifiers
                                             displayName:(NSString *)displayName
                                                   error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return nil; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return nil; }

    id list = IMCPFetch(store, @selector(fetchListWithObjectID:error:), @"REMCDList",
                        listIdentifier, @"reminder list", error);
    if (list == nil) { return nil; }

    // Ordering is rewritten wholesale on save, so the existing sections have to
    // be re-stated or they lose their order.
    NSMutableArray *ordering = [NSMutableArray array];
    for (NSString *identifier in existingSectionIdentifiers) {
        id objectID = IMCPObjectID(@"REMCDListSection", identifier, error);
        if (objectID == nil) { return nil; }
        [ordering addObject:objectID];
    }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return nil; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateList:), error)) { return nil; }
    id listChange = [(IMCPREMShim *)saveRequest updateList:list];
    if (!IMCPRequireSelector(listChange, @selector(sectionsContextChangeItem), error)) {
        return nil;
    }

    id sectionsContext = [(IMCPREMShim *)listChange sectionsContextChangeItem];
    if (sectionsContext == nil) {
        IMCPFail(error, IMCPReminderKitErrorMissingSelector,
                 @"Reminders did not provide a sections context for this list");
        return nil;
    }

    if (!IMCPRequireSelector(saveRequest,
                             @selector(addListSectionWithDisplayName:toListSectionContextChangeItem:),
                             error)) {
        return nil;
    }
    id sectionChange = [(IMCPREMShim *)saveRequest
        addListSectionWithDisplayName:displayName
       toListSectionContextChangeItem:sectionsContext];
    if (!IMCPRequireSelector(sectionChange, @selector(remObjectID), error)) { return nil; }

    id sectionObjectID = [(IMCPREMShim *)sectionChange remObjectID];
    if (sectionObjectID == nil) {
        IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                 @"Reminders did not assign an identifier to the new section");
        return nil;
    }
    [ordering addObject:sectionObjectID];

    if (!IMCPRequireSelector(sectionsContext, @selector(setUnsavedSectionIDsOrdering:), error)
        || !IMCPRequireSelector(sectionsContext, @selector(setShouldUpdateSectionsOrdering:),
                                error)) {
        return nil;
    }
    [(IMCPREMShim *)sectionsContext setUnsavedSectionIDsOrdering:ordering];
    [(IMCPREMShim *)sectionsContext setShouldUpdateSectionsOrdering:YES];

    if (!IMCPSave(saveRequest, @"create the section", error)) { return nil; }

    if (!IMCPRequireSelector(sectionObjectID, @selector(uuid), error)) { return nil; }
    return [(IMCPREMShim *)sectionObjectID uuid].UUIDString;
}

+ (BOOL)renameSectionWithIdentifier:(NSString *)sectionIdentifier
                             toName:(NSString *)name
                              error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return NO; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return NO; }

    id section = IMCPFetch(store, @selector(fetchListSectionWithObjectID:error:),
                           @"REMCDListSection", sectionIdentifier, @"section", error);
    if (section == nil) { return NO; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return NO; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateListSection:), error)) { return NO; }
    id sectionChange = [(IMCPREMShim *)saveRequest updateListSection:section];
    if (!IMCPRequireSelector(sectionChange, @selector(setDisplayName:), error)) { return NO; }

    [(IMCPREMShim *)sectionChange setDisplayName:name];
    return IMCPSave(saveRequest, @"rename the section", error);
}

+ (BOOL)deleteSectionWithIdentifier:(NSString *)sectionIdentifier
                              error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return NO; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return NO; }

    id section = IMCPFetch(store, @selector(fetchListSectionWithObjectID:error:),
                           @"REMCDListSection", sectionIdentifier, @"section", error);
    if (section == nil) { return NO; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return NO; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateListSection:), error)) { return NO; }
    id sectionChange = [(IMCPREMShim *)saveRequest updateListSection:section];
    if (!IMCPRequireSelector(sectionChange, @selector(removeFromList), error)) { return NO; }

    // Deliberately no cascade: the section's reminders stay on the list and
    // become unsectioned, which is what the Reminders app does.
    [(IMCPREMShim *)sectionChange removeFromList];
    return IMCPSave(saveRequest, @"delete the section", error);
}

+ (BOOL)assignReminderWithIdentifier:(NSString *)reminderIdentifier
             toSectionWithIdentifier:(NSString *)sectionIdentifier
                inListWithIdentifier:(NSString *)listIdentifier
                               error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return NO; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return NO; }

    id reminderObjectID = IMCPObjectID(@"REMCDReminder", reminderIdentifier, error);
    if (reminderObjectID == nil) { return NO; }
    id sectionObjectID = IMCPObjectID(@"REMCDListSection", sectionIdentifier, error);
    if (sectionObjectID == nil) { return NO; }

    // Fetching each target first proves all three exist before anything is saved.
    if (IMCPFetch(store, @selector(fetchReminderWithObjectID:error:), @"REMCDReminder",
                  reminderIdentifier, @"reminder", error) == nil) {
        return NO;
    }
    if (IMCPFetch(store, @selector(fetchListSectionWithObjectID:error:), @"REMCDListSection",
                  sectionIdentifier, @"section", error) == nil) {
        return NO;
    }
    id list = IMCPFetch(store, @selector(fetchListWithObjectID:error:), @"REMCDList",
                        listIdentifier, @"reminder list", error);
    if (list == nil) { return NO; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return NO; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateList:), error)) { return NO; }
    id listChange = [(IMCPREMShim *)saveRequest updateList:list];
    if (!IMCPRequireSelector(listChange, @selector(sectionsContextChangeItem), error)) {
        return NO;
    }
    id sectionsContext = [(IMCPREMShim *)listChange sectionsContextChangeItem];
    if (!IMCPRequireSelector(sectionsContext,
                             @selector(setUnsavedMembershipsOfRemindersInSections:), error)) {
        return NO;
    }

    if (!IMCPRequireSelector(reminderObjectID, @selector(uuid), error)
        || !IMCPRequireSelector(sectionObjectID, @selector(uuid), error)) {
        return NO;
    }

    id membership = [NSClassFromString(@"REMMembership") alloc];
    if (!IMCPRequireSelector(membership,
                             @selector(initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:),
                             error)) {
        return NO;
    }
    membership = [(IMCPREMShim *)membership
        initWithMemberIdentifier:[(IMCPREMShim *)reminderObjectID uuid]
                 groupIdentifier:[(IMCPREMShim *)sectionObjectID uuid]
                      isObsolete:NO
                      modifiedOn:[NSDate date]];
    if (membership == nil) {
        return IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                        @"Could not describe the reminder's section membership");
    }

    id memberships = [NSClassFromString(@"REMMemberships") alloc];
    if (!IMCPRequireSelector(memberships, @selector(initWithMemberships:), error)) { return NO; }
    memberships = [(IMCPREMShim *)memberships initWithMemberships:@[membership]];
    if (memberships == nil) {
        return IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                        @"Could not describe the reminder's section membership");
    }

    // Only the one new membership is submitted; ReminderKit merges it with the
    // list's existing memberships rather than replacing them.
    [(IMCPREMShim *)sectionsContext setUnsavedMembershipsOfRemindersInSections:memberships];

    return IMCPSave(saveRequest, @"move the reminder into the section", error);
}

+ (nullable NSString *)createTemplateNamed:(NSString *)name
                    fromListWithIdentifier:(NSString *)listIdentifier
                          includeCompleted:(BOOL)includeCompleted
                                     error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return nil; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return nil; }

    if (IMCPFetch(store, @selector(fetchListWithObjectID:error:), @"REMCDList", listIdentifier,
                  @"reminder list", error) == nil) {
        return nil;
    }
    id listObjectID = IMCPObjectID(@"REMCDList", listIdentifier, error);
    if (listObjectID == nil) { return nil; }

    id account = IMCPPrimaryAccount(store, error);
    if (account == nil) { return nil; }

    id configuration = [NSClassFromString(@"REMTemplateConfiguration") alloc];
    if (!IMCPRequireSelector(configuration,
                             @selector(initWithSourceListID:shouldSaveCompleted:), error)) {
        return nil;
    }
    configuration = [(IMCPREMShim *)configuration initWithSourceListID:listObjectID
                                                  shouldSaveCompleted:includeCompleted];
    if (configuration == nil) {
        IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                 @"Could not describe the template to save");
        return nil;
    }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return nil; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateAccount:), error)) { return nil; }
    id accountChange = [(IMCPREMShim *)saveRequest updateAccount:account];
    if (accountChange == nil) {
        IMCPFail(error, IMCPReminderKitErrorNoAccount,
                 @"Reminders did not provide an editable account");
        return nil;
    }

    if (!IMCPRequireSelector(saveRequest,
                             @selector(addTemplateWithName:configuration:toAccountChangeItem:),
                             error)) {
        return nil;
    }
    id templateChange = [(IMCPREMShim *)saveRequest addTemplateWithName:name
                                                         configuration:configuration
                                                   toAccountChangeItem:accountChange];
    if (templateChange == nil) {
        IMCPFail(error, IMCPReminderKitErrorSaveFailed, @"Reminders refused to add the template");
        return nil;
    }

    if (!IMCPSave(saveRequest, @"save the list as a template", error)) { return nil; }

    if (!IMCPRequireSelector(templateChange, @selector(remObjectID), error)) { return nil; }
    id templateObjectID = [(IMCPREMShim *)templateChange remObjectID];
    if (!IMCPRequireSelector(templateObjectID, @selector(uuid), error)) { return nil; }
    return [(IMCPREMShim *)templateObjectID uuid].UUIDString;
}

+ (nullable NSString *)createListFromTemplateWithIdentifier:(NSString *)templateIdentifier
                                                      error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return nil; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return nil; }

    id templateObject = IMCPFetch(store, @selector(fetchTemplateWithObjectID:error:),
                                  @"REMCDTemplate", templateIdentifier, @"template", error);
    if (templateObject == nil) { return nil; }

    id account = IMCPPrimaryAccount(store, error);
    if (account == nil) { return nil; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return nil; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateAccount:), error)) { return nil; }
    id accountChange = [(IMCPREMShim *)saveRequest updateAccount:account];
    if (accountChange == nil) {
        IMCPFail(error, IMCPReminderKitErrorNoAccount,
                 @"Reminders did not provide an editable account");
        return nil;
    }

    if (!IMCPRequireSelector(saveRequest, @selector(addListUsingTemplate:toAccountChangeItem:),
                             error)) {
        return nil;
    }
    id listChange = [(IMCPREMShim *)saveRequest addListUsingTemplate:templateObject
                                                toAccountChangeItem:accountChange];
    if (listChange == nil) {
        IMCPFail(error, IMCPReminderKitErrorSaveFailed,
                 @"Reminders refused to create a list from this template");
        return nil;
    }

    if (!IMCPSave(saveRequest, @"create a list from the template", error)) { return nil; }

    if (!IMCPRequireSelector(listChange, @selector(remObjectID), error)) { return nil; }
    id listObjectID = [(IMCPREMShim *)listChange remObjectID];
    if (!IMCPRequireSelector(listObjectID, @selector(uuid), error)) { return nil; }
    return [(IMCPREMShim *)listObjectID uuid].UUIDString;
}

+ (BOOL)renameListWithIdentifier:(NSString *)listIdentifier
                          toName:(NSString *)name
                           error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return NO; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return NO; }

    id list = IMCPFetch(store, @selector(fetchListWithObjectID:error:), @"REMCDList",
                        listIdentifier, @"reminder list", error);
    if (list == nil) { return NO; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return NO; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateList:), error)) { return NO; }
    id listChange = [(IMCPREMShim *)saveRequest updateList:list];
    if (!IMCPRequireSelector(listChange, @selector(setName:), error)) { return NO; }

    [(IMCPREMShim *)listChange setName:name];
    return IMCPSave(saveRequest, @"rename the list", error);
}

+ (BOOL)deleteTemplateWithIdentifier:(NSString *)templateIdentifier
                               error:(NSError **)error {
    if (!IMCPRequireAvailable(error)) { return NO; }

    id store = IMCPMakeStore(error);
    if (store == nil) { return NO; }

    id templateObject = IMCPFetch(store, @selector(fetchTemplateWithObjectID:error:),
                                  @"REMCDTemplate", templateIdentifier, @"template", error);
    if (templateObject == nil) { return NO; }

    id saveRequest = IMCPMakeSaveRequest(store, error);
    if (saveRequest == nil) { return NO; }

    if (!IMCPRequireSelector(saveRequest, @selector(updateTemplate:), error)) { return NO; }
    id templateChange = [(IMCPREMShim *)saveRequest updateTemplate:templateObject];
    if (!IMCPRequireSelector(templateChange, @selector(removeFromParentAccount), error)) {
        return NO;
    }

    [(IMCPREMShim *)templateChange removeFromParentAccount];
    return IMCPSave(saveRequest, @"delete the template", error);
}

@end
