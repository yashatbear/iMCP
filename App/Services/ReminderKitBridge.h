#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Write access to Reminders *sections* and *templates*.
///
/// EventKit exposes no API at all for sections (the headings added in macOS
/// Sonoma) or for templates. The only way to create them is Apple's private,
/// undocumented `ReminderKit` framework, which is what this type wraps.
///
/// Safety rules this bridge enforces, deliberately:
///
///  * Every entry point takes **concrete identifiers**, never names. Resolving a
///    user-supplied name to exactly one identifier is the caller's job, so an
///    ambiguous name can never reach a save request.
///  * Every identifier is validated as a UUID before it is interpolated into a
///    `x-apple-reminderkit://` URL, so nothing else can be smuggled in.
///  * Every private selector is probed with `-respondsToSelector:` before it is
///    sent. If a macOS update changes the private surface, these calls fail with
///    a readable error instead of crashing.
///  * `ReminderKit` is loaded with `dlopen` rather than linked, so the app keeps
///    launching normally if the framework ever moves or disappears.
///
/// Nothing here cascades: deleting a section leaves its reminders in place
/// (unsectioned), which is what the Reminders app itself does.
@interface IMCPReminderKit : NSObject

/// Whether the private framework loaded and exposes the classes we need.
@property (class, readonly) BOOL isAvailable;

/// The sections on one list, in display order, as `name` / `identifier` pairs.
///
/// This asks the Reminders daemon rather than reading the local SQLite store, so
/// unlike `RemindersDatabase` it needs only Reminders access, not Full Disk
/// Access. Section *membership* still comes from the database.
+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)
    sectionsInListWithIdentifier:(NSString *)listIdentifier
                           error:(NSError **)error NS_SWIFT_NAME(sections(inList:));

/// Every saved template, as `name` / `identifier` pairs. Also daemon-backed.
+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)templatesWithError:(NSError **)error
    NS_SWIFT_NAME(templates());

/// Creates a section on an existing list.
///
/// `existingSectionIdentifiers` must be every section currently on the list, in
/// display order. ReminderKit rewrites the whole section ordering on save, so
/// omitting them silently reorders (or drops) the list's existing sections.
///
/// Returns the new section's identifier.
+ (nullable NSString *)createSectionInListWithIdentifier:(NSString *)listIdentifier
                              existingSectionIdentifiers:(NSArray<NSString *> *)existingSectionIdentifiers
                                             displayName:(NSString *)displayName
                                                   error:(NSError **)error
    NS_SWIFT_NAME(createSection(inList:existingSectionIdentifiers:displayName:));

/// Renames one section.
+ (BOOL)renameSectionWithIdentifier:(NSString *)sectionIdentifier
                             toName:(NSString *)name
                              error:(NSError **)error
    NS_SWIFT_NAME(renameSection(identifier:name:));

/// Deletes one section. Its reminders survive and become unsectioned.
+ (BOOL)deleteSectionWithIdentifier:(NSString *)sectionIdentifier
                              error:(NSError **)error
    NS_SWIFT_NAME(deleteSection(identifier:));

/// Moves one already-existing reminder into one section of the list it lives in.
+ (BOOL)assignReminderWithIdentifier:(NSString *)reminderIdentifier
             toSectionWithIdentifier:(NSString *)sectionIdentifier
                inListWithIdentifier:(NSString *)listIdentifier
                               error:(NSError **)error
    NS_SWIFT_NAME(assignReminder(identifier:sectionIdentifier:listIdentifier:));

/// Saves an existing list as a new template. Returns the template's identifier.
+ (nullable NSString *)createTemplateNamed:(NSString *)name
                    fromListWithIdentifier:(NSString *)listIdentifier
                          includeCompleted:(BOOL)includeCompleted
                                     error:(NSError **)error
    NS_SWIFT_NAME(createTemplate(named:fromList:includeCompleted:));

/// Creates a list from a template. Returns the new list's identifier.
///
/// The new list inherits the *template's* name; ReminderKit offers no way to
/// name it here. Follow up with `renameListWithIdentifier:toName:error:`.
+ (nullable NSString *)createListFromTemplateWithIdentifier:(NSString *)templateIdentifier
                                                      error:(NSError **)error
    NS_SWIFT_NAME(createList(fromTemplate:));

/// Renames one list.
+ (BOOL)renameListWithIdentifier:(NSString *)listIdentifier
                          toName:(NSString *)name
                           error:(NSError **)error
    NS_SWIFT_NAME(renameList(identifier:name:));

/// Deletes one saved template. Lists made from it are untouched.
+ (BOOL)deleteTemplateWithIdentifier:(NSString *)templateIdentifier
                               error:(NSError **)error
    NS_SWIFT_NAME(deleteTemplate(identifier:));

@end

NS_ASSUME_NONNULL_END
