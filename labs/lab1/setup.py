from setuptools import Extension, setup

setup(
    name='codegen',
    version='0.1.0',
    python_requires='>=3.10',
    build_zig=True,
    ext_modules=[
        Extension(
            'pyzigtest',
            sources=[
                'src/ast/codegen.zig'
            ],
            extra_compile_args=["-ODebug"]
        )
    ],
    setup_requires=['setuptools-zig'],
)
