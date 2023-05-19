from snakebids import bids

configfile: 'config.yml'

sample_wildcards=config['sample_wildcards']
slice_wildcards=config['slice_wildcards']
root=config['root']

  
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


