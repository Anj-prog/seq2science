import requests


rule bedgraphish_to_bedgraph:
    """
    Convert the bedgraph-ish file generated by genrich into true bedgraph file.
    """
    input:
        expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bdgish", **config)
    output:
        bedgraph=expand("{result_dir}/genrich/{{assembly}}-{{sample}}.bedgraph", **config)
    log:
        expand("{log_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}.log", **config)[0]
    shell:
        """
        splits=$(grep -Pno "([^\/]*)(?=\.bam)" {input})
        splits=($splits)
        lncnt=$(wc -l {input} | echo "$(grep -Po ".*(?=\ )")":)
        splits+=($lncnt)

        counter=1
        for split in "${{splits[@]::${{#splits[@]}}-1}}";
        do
            filename=$(grep -Po "(?<=:).*" <<< $split);
            if [[ $filename =~ {wildcards.sample} ]]; then
                startnr=$(grep -Po ".*(?=\:)" <<< $split);
                endnr=$(grep -Po ".*(?=\:)" <<< ${{splits[counter]}});

                lines="NR>=startnr && NR<=endnr {{ print \$1, \$2, \$3, \$4 }}"
                lines=${{lines/startnr/$((startnr + 2))}}
                lines=${{lines/endnr/$((endnr - 1))}}

                awk "$lines" {input} > {output}
            fi
            ((counter++))
        done
        """


def find_bedgraph(wildcards):
    if wildcards.peak_caller == 'genrich':
        suffix = '.bedgraph'
    elif wildcards.peak_caller == 'macs2':
        suffix = '_treat_pileup.bdg'
    else:
        suffix = '.bedgraph'

    return f"{config['result_dir']}/{wildcards.peak_caller}/{wildcards.assembly}-{wildcards.sample}{suffix}"


rule bedgraph_bigwig:
    """
    Convert a bedgraph file into a bigwig.
    """
    input:
        bedgraph=find_bedgraph,
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bw", **config),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bedgraphtmp", **config))
    log:
        expand("{log_dir}/bedgraph_bigwig/{{peak_caller}}/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        awk -v OFS='\\t' '{{print $1, $2, $3, $4}}' {input.bedgraph} | sed '/experimental/d' |
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedGraphToBigWig {output.tmp} {input.genome_size} {output.out} > {log} 2>&1
        """


rule narrowpeak_bignarrowpeak:
    """
    Convert a narrowpeak file into a bignarrowpeak file.
    """
    input:
        narrowpeak= expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}_peaks.narrowPeak", **config),
        genome_size=expand("{genome_dir}/{{assembly}}/{{assembly}}.fa.sizes", **config)
    output:
        out=     expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.bigNarrowPeak", **config),
        tmp=temp(expand("{result_dir}/{{peak_caller}}/{{assembly}}-{{sample}}.tmp.narrowPeak", **config))
    log:
        expand("{log_dir}/narrowpeak_bignarrowpeak/{{peak_caller}}/{{assembly}}-{{sample}}.log", **config)
    benchmark:
        expand("{benchmark_dir}/bedgraphish_to_bedgraph/{{assembly}}-{{sample}}-{{peak_caller}}.log", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        """
        # keep first 10 columns, idr adds extra columns we do not need for our bigpeak
        cut -d$'\t' -f 1-10 {input.narrowpeak} |
        bedSort /dev/stdin {output.tmp} > {log} 2>&1;
        bedToBigBed -type=bed4+6 -as=../../schemas/bigNarrowPeak.as {output.tmp} {input.genome_size} {output.out} > {log} 2>&1
        """


def get_strandedness(wildcards):
    sample = f"{wildcards.sample}"
    strandedness = samples["strandedness"].loc[sample]
    return strandedness


rule bam_stranded_bigwig:
    """
    Convert a bam file into two bigwig files, one for each strand    
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        forward=expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.fwd.bw", **config),
        reverse=expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.rev.bw", **config),
    params:
        flags=config['deeptools'],
        strandedness=get_strandedness
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order', False) else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 20
    resources:
        deeptools_limit=1
    shell:
        """       
        direction1=forward
        direction2=reverse
        if [ {params.strandedness} == 'reverse' ]; then
            direction1=reverse
            direction2=forward
        fi
                    
        bamCoverage --bam {input.bam} --outFileName {output.forward} --filterRNAstrand $direction1 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1 &&        
        bamCoverage --bam {input.bam} --outFileName {output.reverse} --filterRNAstrand $direction2 --numberOfProcessors {threads} {params.flags} --verbose >> {log} 2>&1
        """

rule bam_bigwig:
    """
    Convert a bam file into a bigwig file
    """
    input:
        bam=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam", **config),
        bai=expand("{dedup_dir}/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bam.bai", **config)
    output:
        expand("{result_dir}/bigwigs/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.bw", **config)
    params:
        config['deeptools']
    wildcard_constraints:
        sorting=config['bam_sort_order'] if config.get('bam_sort_order') else ""
    log:
        expand("{log_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.log", **config),
    benchmark:
        expand("{benchmark_dir}/bam_bigwig/{{assembly}}-{{sample}}.{{sorter}}-{{sorting}}.benchmark.txt", **config)[0]
    conda:
        "../envs/deeptools.yaml"
    threads: 20
    resources:
        deeptools_limit=1
    shell:
        """
        bamCoverage --bam {input.bam} --outFileName {output} --numberOfProcessors {threads} {params} --verbose >> {log} 2>&1
        """


rule twobit:
    """
    Generate a 2bit file for each assembly
    """
    input:
        expand("{genome_dir}/{{assembly}}/{{assembly}}.fa", **config)
    output:
        expand("{genome_dir}/{{assembly}}/{{assembly}}.2bit", **config)
    log:
        expand("{log_dir}/assembly_hub/{{assembly}}.2bit.log", **config)
    benchmark:
        expand("{benchmark_dir}/assembly_hub/{{assembly}}.2bit.benchmark.txt", **config)[0]
    conda:
        "../envs/ucsc.yaml"
    shell:
        "faToTwoBit {input} {output}"


def get_bigwig_strand(sample):
    """
    return a list of extensions for (un)stranded bigwigs
    """
    if 'strandedness' in samples and config['filter_bam_by_strand']:
        strandedness = samples["strandedness"].loc[sample]
        if strandedness in ['forward', 'yes', 'reverse']:
            return ['.fwd', '.rev']
    return ['']


def get_trackhub_files(wildcards):
    """

    """
    trackfiles = {key: [] for key in ['bigwigs', 'bigpeaks', 'twobits', 'annotations']}

    # check whether or not each assembly is supported by ucsc
    for assembly in set(samples['assembly']):
        # check for response of ucsc
        response = requests.get(f"https://genome.ucsc.edu/cgi-bin/hgTracks?db={assembly}",
                                allow_redirects=True)
        assert response.ok, "Make sure you are connected to the internet"

        # see if the title of the page mentions our assembly
        if not any(assembly == x for x in
                   re.search(r'<TITLE>(.*?)</TITLE>', response.text).group(1).split(' ')):
            trackfiles['twobits'].append(f"{config['genome_dir']}/{assembly}/{assembly}.2bit")

        # now check if we have annotation for
        # TODO

    # Get the ATAC or RNA seq files
    if 'atac_seq' in workflow.snakefile.split('/')[-2]:
        # get all the peak files for all replicates or for the replicates combined
        if 'condition' in samples:
            for condition in set(samples['condition']):
                for assembly in set(samples[samples['condition'] == condition]['assembly']):
                    trackfiles['bigpeaks'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{assembly}-{condition}.bigNarrowPeak", **config))
        else:
            for sample in samples.index:
                trackfiles['bigpeaks'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{samples.loc[sample, 'assembly']}-{sample}.bigNarrowPeak", **config))

        # get all the bigwigs
        if config.get('combine_replicates', '') == 'merge' and 'condition' in samples:
            for condition in set(samples['condition']):
                for assembly in set(samples[samples['condition'] == condition]['assembly']):
                    trackfiles['bigwigs'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{assembly}-{condition}.bw", **config))
        else:
            for sample in samples.index:
                trackfiles['bigwigs'].extend(expand(f"{{result_dir}}/{{peak_caller}}/{samples.loc[sample, 'assembly']}-{sample}.bw", **config))

    elif 'rna_seq' in workflow.snakefile.split('/')[-2]:
        # get all the bigwigs
        if config.get('combine_replicates', '') == 'merge' and 'condition' in samples:
            for condition in set(samples['condition']):
                for assembly in set(samples[samples['condition'] == condition]['assembly']):
                    for bw in get_bigwig_strand(sample):
                        bw = expand(f"{{result_dir}}/bigwigs/{assembly}-{condition}.{config['bam_sorter']}-{config['bam_sort_order']}{bw}.bw", **config)
                        trackfiles['bigwigs'].extend(bw)
        else:
            for sample in samples.index:
                for bw in get_bigwig_strand(sample):
                    bw = expand(f"{{result_dir}}/bigwigs/{samples.loc[sample]['assembly']}-{sample}.{config['bam_sorter']}-{config['bam_sort_order']}{bw}.bw", **config)
                    trackfiles['bigwigs'].extend(bw)

    return trackfiles


def get_defaultPos(sizefile):
    # extract a default position spanning the first scaffold/chromosome in the sizefile.
    with open(sizefile, 'r') as file:
        dflt = file.readline().strip('\n').split('\t')
    return dflt[0] + ':0-' + str(min(int(dflt[1]), 100000))


rule trackhub:
    """
    Generate a trackhub which has to be hosted on your own machine, but can then be viewed through 
    the UCSC genome browser.
    
    Must be hosted on your own machine in order to be viewed through the UCSC genome browser.
    """
    input:
        unpack(get_trackhub_files)
    output:
        directory(f"{config['result_dir']}/trackhub")
    log:
        f"{config['log_dir']}/trackhub.log"
    benchmark:
        f"{config['benchmark_dir']}/trackhub.benchmark.txt"
    run:
        import re
        import trackhub
        from contextlib import redirect_stdout

        with open(log[0], 'w') as f:
            # contextlib.redirect_stderr doesn't work. Probably an issue with trackhub
            with redirect_stdout(f):
                orderkey = 4800

                # make the output directory
                shell(f"mkdir -p {output[0]}")

                # start a shared hub
                hub = trackhub.Hub(
                    hub        =config.get('hubname',    'trackhub'),
                    short_label=config.get('shortlabel', 'trackhub'), # 17 characters max
                    long_label =config.get('longlabel',  "Automated trackhub generated by the snakemake-workflows tool: \n"
                                                         "https://github.com/vanheeringen-lab/snakemake-workflows"),
                    email      =config.get('email',      'none@provided.com'))

                # link the genomes file to the hub
                genomes_file = trackhub.genomes_file.GenomesFile()
                hub.add_genomes_file(genomes_file)

                for assembly in set(samples['assembly']):
                    # now add each assembly to the genomes_file
                    if any(assembly in twobit for twobit in input.twobits):
                        basename = f"{config['genome_dir']}/{assembly}/{assembly}"
                        genome = trackhub.Assembly(
                            genome=assembly,
                            twobit_file=basename + '.2bit',
                            organism=assembly,
                            defaultPos=get_defaultPos(basename + '.fa.sizes'),
                            scientificName=assembly,
                            description=assembly
                        )
                    else:
                        genome = trackhub.Genome(assembly)

                    genomes_file.add_genome(genome)

                    # each trackdb is added to the genome
                    trackdb = trackhub.trackdb.TrackDb()
                    genome.add_trackdb(trackdb)
                    priority = 1

                    # now add the data files depending on the workflow
                    # ATAC-seq trackhub
                    if 'atac_seq' in workflow.snakefile.split('/')[-2]:
                        for peak_caller in config['peak_caller']:
                            conditions = set()
                            for sample in samples[samples['assembly'] == assembly].index:
                                if 'condition' in samples:
                                    if samples.loc[sample, 'condition'] not in conditions:
                                        bigpeak = f"{config['result_dir']}/{peak_caller}/{assembly}-{samples.loc[sample, 'condition']}.bigNarrowPeak"
                                    else:
                                        bigpeak = False
                                    conditions.add(samples.loc[sample, 'condition'])
                                    sample_name = f"{samples.loc[sample, 'condition']}{peak_caller}PEAK"
                                else:
                                    bigpeak = f"{config['result_dir']}/{peak_caller}/{assembly}-{sample}.bigNarrowPeak"
                                    sample_name = f"{sample}{peak_caller}PEAK"
                                sample_name = trackhub.helpers.sanitize(sample_name)

                                if bigpeak:
                                    track = trackhub.Track(
                                        name=sample_name,           # track names can't have any spaces or special chars.
                                        source=bigpeak,             # filename to build this track from
                                        visibility='dense',         # shows the full signal
                                        tracktype='bigNarrowPeak',  # required when making a track
                                        priority=priority
                                    )
                                    priority += 1
                                    trackdb.add_tracks(track)

                                bigwig = f"{config['result_dir']}/{peak_caller}/{assembly}-{sample}.bw"
                                sample_name = f"{sample}{peak_caller}BW"

                                track = trackhub.Track(
                                    name=sample_name,    # track names can't have any spaces or special chars.
                                    source=bigwig,       # filename to build this track from
                                    visibility='full',   # shows the full signal
                                    color='0,0,0',       # black
                                    autoScale='on',      # allow the track to autoscale
                                    tracktype='bigWig',  # required when making a track
                                    priority=priority,
                                    maxHeightPixels='100:32:8'
                                )

                                # each track is added to the trackdb
                                trackdb.add_tracks(track)
                                priority += 1

                    # RNA-seq trackhub
                    elif 'rna_seq' in workflow.snakefile.split('/')[-2]:
                        iterator = samples.index
                        if config.get('combine_replicates', '') == 'merge' and 'condition' in samples:
                            iterator = set(samples['condition'])

                        for sample in iterator:
                            for bw in get_bigwig_strand(sample):
                                bigwig = f"{config['result_dir']}/bigwigs/{assembly}-{sample}.{config['bam_sorter']}-{config['bam_sort_order']}{bw}.bw"
                                sample_name = f"{sample}{bw}"
                                # remove characters trackhub doesn't allow
                                sample_name = re.sub(r'\W+', '', sample_name)

                                track = trackhub.Track(
                                    name=sample_name,    # track names can't have any spaces or special chars.
                                    source=bigwig,       # filename to build this track from
                                    visibility='full',   # shows the full signal
                                    color='0,0,0',       # black
                                    autoScale='on',      # allow the track to autoscale
                                    tracktype='bigWig',  # required when making a track
                                    priority=priority,
                                    maxHeightPixels='100:32:8'
                                )

                                # each track is added to the trackdb
                                trackdb.add_tracks(track)
                                priority += 1

                # now finish by storing the result
                trackhub.upload.upload_hub(hub=hub, host='localhost', remote_dir=output[0])
