from snakebids import bids
import numpy as np
from math import log2

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
        stack=expand(bids(root=root,**sample_wildcards,desc='preproc',stage='{stage}',suffix='zstack.nii'),
            subject=config['subjects'],
            stain=config['stains'],
            downsample=config['downsamples'],
            stage=config['final_stage'])

rule download_data:
    params:
        in_url=config['in_url'],
        script='scripts/get_dzi.js',
        dspow=lambda wildcards: int(log2(int(wildcards.downsample)))
    output:
        raw_dir=directory(bids(root=root,**sample_wildcards,desc='raw',suffix='slices'))
    shell:
        'node {params.script} --base-url {params.in_url} --subject {wildcards.subject} --stain {wildcards.stain} --dspow  {params.dspow} --out-dir {output.raw_dir}'

checkpoint get_number_slices:
    input:
        slice_dir=bids(root=root,**sample_wildcards,desc='raw',suffix='slices')
    output:
        bids(root=root,**sample_wildcards,suffix='numslices.txt')
    shell:
        'ls {input}/*.jpg | wc -l > {output}'

rule conform_slices_to_same_size:
    input: 
        slice_dir=bids(root=root,**sample_wildcards,desc='raw',suffix='slices'),
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
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii')
    shell:
        'c3d {input.slice_dir}/* -tile z -spacing {params.spacing} -orient {params.orient} {output.stack}' 


rule create_mask:
    input:
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii')
    output:
        mask=bids(root=root,**sample_wildcards,suffix='mask.nii')
    shell:
        'c3d {input.stack} -threshold 235 256 0 1 {output.mask}' 

rule apply_mask:
    input:
        stack=bids(root=root,**sample_wildcards,suffix='zstack.nii'),
        mask=bids(root=root,**sample_wildcards,suffix='mask.nii')
    output:
        preproc=bids(root=root,**sample_wildcards,desc='preproc',stage=0,suffix='zstack.nii')
    shell:
        'c3d {input.stack} {input.mask} -multiply -o {output.preproc}'


rule extract_lh_template:
    input:
        template=config['template_brain']
    output:
        hemi=bids(root=root,subject='template',hemi='L',suffix='T1w.nii')
    shell:
        'c3d {input.template} -cmv -pop -pop  -thresh 50% inf 0 1 -as MASK {input.template} -times -o {output.hemi}'

rule reg_stack_to_template_hemi:
    input:
        fixed=bids(root=root,subject='template',hemi='L',suffix='T1w.nii'),
        moving=bids(root=root,**sample_wildcards,desc='preproc',stage='{stage}',suffix='zstack.nii')
    output:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='hist',to='template',stage='{stage}',suffix='xfm.txt'),
    log: 
        bids(root='logs',**sample_wildcards,datatype='reg_stack_to_template_hemi',stage='{stage}',suffix='log.txt')
    threads: 16
    shell:
        'greedy -threads {threads} -d 3 -i {input.fixed} {input.moving} -o {output.xfm} -a -dof 6 -ia-image-centers > {log}'


rule invert_transform:
    input:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='hist',to='template',stage='{stage}',suffix='xfm.txt'),
    output:
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='template',to='hist',stage='{stage}',suffix='xfm.txt'),
    shell:
        'c3d_affine_tool {input} -inv -o {output}'
    

rule transform_template_to_stack:
    input:
        moving=bids(root=root,subject='template',hemi='L',suffix='T1w.nii'),
        fixed=bids(root=root,**sample_wildcards,desc='preproc',stage='{stage}',suffix='zstack.nii'),
        xfm=bids(root=root,**sample_wildcards,desc='rigid',from_='template',to='hist',stage='{stage}',suffix='xfm.txt'),
    output:
        warped=bids(root=root,**sample_wildcards,desc='rigidtemplate',stage='{stage}',suffix='T1w.nii')
    log: 
        bids(root='logs',**sample_wildcards,datatype='transform_template_to_stack',stage='{stage}',suffix='log.txt')
    threads: 4
    shell:
        'greedy -threads {threads} -d 3 -r {input.xfm} -rf {input.fixed} -rm {input.moving} {output.warped} > {log}'


rule extract_template_slice:
    input:
        template_vol=bids(root=root,**sample_wildcards,desc='rigidtemplate',stage='{stage}',suffix='T1w.nii')
    output:
        template_slice=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='rigidtemplate',slice='{slice}',suffix='T1w.nii')
    shell:
        'c3d {input} -slice z {wildcards.slice} -o {output}'

rule extract_hist_slice:
    input:
        hist_stack=bids(root=root,**sample_wildcards,desc='preproc',stage='{stage}',suffix='zstack.nii'),
    output:
        hist_slice=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='preproc',slice='{slice}',suffix='hist.nii')
    shell:
        'c3d {input} -slice z {wildcards.slice} -o {output}'

rule register_slices:
    input:
        template_slice=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='rigidtemplate',slice='{slice}',suffix='T1w.nii'),
        hist_slice=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='preproc',slice='{slice}',suffix='hist.nii')
    params:
        affine_opts='-ia-image-centers -dof 6 -m MI  ',#-search 2000 flip 0',
        nlin_opts='-m NMI -n 10x10',

    output:
        nlin_warp=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='preproc',slice='{slice}',suffix='warp.nii'),
        affine_xfm=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='preproc',slice='{slice}',suffix='xfm.txt'),
        hist_warped=bids(root=root,**sample_wildcards,datatype='reg2d_stage-{stage}',desc='warped',slice='{slice}',suffix='hist.nii')
    threads: 4
    log: 
        bids(root='logs',**sample_wildcards,datatype='register_slices',stage='{stage}',slice='{slice}',suffix='log.txt') 
    shell:
        'greedy -threads {threads} -d 2 -i {input.template_slice} {input.hist_slice} -o {output.affine_xfm} -a {params.affine_opts} > {log} && ' 
        'greedy -threads {threads} -d 2 -i {input.template_slice} {input.hist_slice} -o {output.nlin_warp} -it {output.affine_xfm} {params.nlin_opts} >> {log} && '
        'greedy -threads {threads} -d 2 -r {output.nlin_warp} {output.affine_xfm} -rf {input.template_slice} -rm {input.hist_slice} {output.hist_warped} >> {log} '

def get_registered_hist_slices(wildcards):
    checkpoint_output = checkpoints.get_number_slices.get(**wildcards).output[0]
    #read the text file to get the number of slices
    n_slices = np.loadtxt(checkpoint_output, dtype=int)
    prev_stage = int(wildcards.stage) - 1
    hist_slices=expand(bids(root=root,**sample_wildcards,datatype='reg2d_stage-{prev_stage}',desc='warped',slice='{slice}',suffix='hist.nii'),
            **wildcards,
            prev_stage=prev_stage,
            slice=range(n_slices))
    return hist_slices


rule stack_registered_slices:
    input:
        hist_slices=get_registered_hist_slices   
    params:
        spacing=get_spacing,
        orient=config['orient']
    output:
        hist_stack=bids(root=root,**sample_wildcards,desc='preproc',stage='{stage,[1-9][0-9]*}',suffix='zstack.nii'),
    shell:
        'c3d {input.hist_slices} -tile z -spacing {params.spacing} -orient {params.orient} {output.hist_stack}' 



