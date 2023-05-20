from snakebids import bids

configfile: 'config.yml'

sample_wildcards=config['sample_wildcards']
slice_wildcards=config['slice_wildcards']
root=config['root']

wildcard_constraints:
    downsample='[0-9]+',
    subject='[a-zA-Z0-9]+',
    stain='[a-zA-Z0-9]+'


rule all:
    input:
        stack=expand(bids(root=root,**sample_wildcards,suffix='zstack.nii.gz'),subject='B79',stain='Nissl',downsample=128)

rule conform_slices_to_same_size:
    input: 
        slice_dir=config['in_raw_dir'],
        conform_script='scripts/conform_slices.sh'
    output:
        slice_dir=directory(bids(root=root,**sample_wildcards,desc='conformed',suffix='slices'))
    shell:
        '{input.conform_script} {input.slice_dir} {output.slice_dir}'

def get_spacing(wildcards):
    
    inplane_mm=config['orig_resolution_um']*float(wildcards.downsample)/1000
    thickness_mm=config['slice_thickness_um']*config['every_n_slices']/1000
    return f'{inplane_mm}x{inplane_mm}x{thickness_mm}mm'

rule convert_to_grayscale_nii:
    input: 
        slice_dir=bids(root=root,**sample_wildcards,desc='conformed',suffix='slices')
    output:
        slice_dir=directory(bids(root=root,**sample_wildcards,desc='grayscale',suffix='slices'))
    shell:
        'mkdir -p {output.slice_dir} && c3d {input.slice_dir}/* -slice-all z 0:-1 -oo {output.slice_dir}/%03d.nii'
    
rule zstack:
    input:
        slice_dir=directory(bids(root=root,**sample_wildcards,desc='grayscale',suffix='slices'))
    params:
        spacing=get_spacing,
        orient=config['orient']
    output:
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii.gz')
    shell:
        'c3d {input.slice_dir}/* -tile z -spacing {params.spacing} -orient {params.orient} {output.stack}' 


rule create_mask:
    input:
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii.gz')
    output:
        mask=bids(root=root,**sample_wildcards,suffix='mask.nii.gz')
    shell:
        'c3d {input.stack} -threshold 235 256 0 1 {output.mask}' 

rule apply_mask:
    input:
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii.gz'),
        mask=bids(root=root,**sample_wildcards,suffix='mask.nii.gz')
    output:
        masked=bids(root=root,**sample_wildcards,desc='masked',suffix='zstack.nii.gz')
    shell:
        'c3d {input.stack} {input.mask} -multiply -o {output.masked}'


rule extract_lh_template:
    input:
        template=config['template_brain']
    output:
        hemi=bids(root=root,subject='template',hemi='L',suffix='T1w.nii.gz')
    shell:
        'c3d {input.template} -cmv -pop -pop  -thresh 50% inf 0 1 -as MASK {input.template} -times -o {output.hemi}'

rule reg_stack_to_template_hemi:
    input:
        fixed=bids(root=root,subject='template',hemi='L',suffix='T1w.nii.gz'),
        moving=bids(root=root,**sample_wildcards,desc='masked',suffix='zstack.nii.gz')
    output:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='hist',to='template',suffix='xfm.txt'),
    shell:
        'greedy -d 3 -i {input.fixed} {input.moving} -o {output.xfm} -a -dof 6 -ia-image-centers'


rule invert_transform:
    input:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='hist',to='template',suffix='xfm.txt'),
    output:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='template',to='hist',suffix='xfm.txt'),
    shell:
        'c3d_affine_tool {input} -inv -o {output}'
    

rule transform_template_to_stack:
    input:
        moving=bids(root=root,subject='template',hemi='L',suffix='T1w.nii.gz'),
        fixed=bids(root=root,**sample_wildcards,desc='masked',suffix='zstack.nii.gz'),
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='template',to='hist',suffix='xfm.txt'),
    output:
        warped=bids(root=root,**sample_wildcards,desc='rigidtemplate',suffix='T1w.nii.gz')
    shell:
        'greedy -d 3 -r {input.xfm} -rf {input.fixed} -rm {input.moving} {output.warped}'


