// language: Objective-C++, file: twin/il2cpp_kit.h, target: iOS 15+, arm64
// *il2cpp symbol bundle resolved at runtime; nothing is linked statically*
// twin stack: symbol table -> domain/assembly/image walk -> class/method invoke.
#ifndef IL2CPP_KIT_H
#define IL2CPP_KIT_H

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>

typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppType Il2CppType;
typedef struct Il2CppString Il2CppString;
typedef struct Il2CppMethod Il2CppMethod;
typedef struct Il2CppObject Il2CppReflectionType;

typedef struct Il2CppArray {
    void *klass;
    void *monitor;
    struct { size_t length; } bounds;
    void *vector;
} Il2CppArray;

typedef struct Il2CppException Il2CppException;

typedef Il2CppDomain *(*fn_domain_get)(void);
typedef const Il2CppAssembly **(*fn_domain_get_assemblies)(Il2CppDomain *, size_t *);
typedef Il2CppImage *(*fn_assembly_get_image)(const Il2CppAssembly *);
typedef size_t (*fn_image_get_class_count)(const Il2CppImage *);
typedef Il2CppClass *(*fn_image_get_class)(const Il2CppImage *, size_t);
typedef const char *(*fn_class_get_name)(Il2CppClass *);
typedef const char *(*fn_class_get_namespace)(Il2CppClass *);
typedef Il2CppMethod *(*fn_class_get_method_from_name)(Il2CppClass *, const char *, int);
typedef void *(*fn_thread_attach)(Il2CppDomain *);
typedef Il2CppObject *(*fn_runtime_invoke)(const Il2CppMethod *, void *, void **, Il2CppException **);
typedef Il2CppType *(*fn_class_get_type)(Il2CppClass *);
typedef Il2CppReflectionType *(*fn_type_get_object)(Il2CppType *);
typedef void *(*fn_class_get_fields)(Il2CppClass *, void **);
typedef size_t (*fn_field_get_offset)(void *);
typedef const char *(*fn_field_get_name)(void *);
typedef Il2CppObject *(*fn_object_new)(Il2CppClass *);
typedef const char *(*fn_method_get_name)(const Il2CppMethod *);

typedef struct {
    fn_domain_get                      domain_get;
    fn_domain_get_assemblies           domain_get_assemblies;
    fn_assembly_get_image              assembly_get_image;
    fn_image_get_class_count           image_get_class_count;
    fn_image_get_class                 image_get_class;
    fn_class_get_name                  class_get_name;
    fn_class_get_namespace             class_get_namespace;
    fn_class_get_method_from_name      class_get_method_from_name;
    fn_thread_attach                   thread_attach;
    fn_runtime_invoke                  runtime_invoke;
    fn_class_get_type                  class_get_type;
    fn_type_get_object                 type_get_object;
    fn_class_get_fields                class_get_fields;
    fn_field_get_offset                field_get_offset;
    fn_field_get_name                  field_get_name;
    fn_object_new                      object_new;
    fn_method_get_name                 method_get_name;
} Il2Kit;

extern Il2Kit g_kit;
extern Il2CppDomain *g_domain;
extern void *g_unity;

// resolve every symbol through dlsym; returns count found (expected 17)
int kit_resolve(void);
// walk assemblies and print namespace.Name (+field offsets) into an NSMutableString
NSString *kit_dump_classes(const char *filter, BOOL with_fields);
// find a class by simple name across every assembly image
Il2CppClass *kit_find_class(const char *simple_name);
// locate a method on klass; argc = number of params, -1 for "any"
Il2CppMethod *kit_method(Il2CppClass *klass, const char *name, int argc);
// invoke with args on the given instance (may be NULL for static)
Il2CppObject *kit_invoke(Il2CppMethod *m, void *self, void **args);
// bounds-safe array element read
void *kit_arr_at(Il2CppArray *arr, size_t i);

#endif
