pipeline {
    agent any
    
    environment {
        IMAGE_NAME = "319790676146.dkr.ecr.ap-south-1.amazonaws.com/devchatbot"
        REGION = "ap-south-1"
        CONTAINER_NAME = "devchatbot_container"
        
		SONAR_PROJECT_KEY = 'chatbot-pipeline'
		SONAR_SCANNER_HOME = tool 'SonarQubeScanner'
		}

    stages {
        stage('Pull the code from GitHub to Jenkins workspace') {
            steps {
                git branch: "dev", credentialsId: 'Github-token-thomas-futureik', url: 'https://github.com/Jinu-Jogy/Asta_PixelAIAssistant.git'
            }
        }

        stage('SonarQube Analysis'){
            steps {
                withCredentials([string(credentialsId: 'chatbot-pipeline-sonar-token', variable: 'SONAR_TOKEN')]) {
                    withSonarQubeEnv('sonarqube') {
			                sh """
                                               ${SONAR_SCANNER_HOME}/bin/sonar-scanner \
                                               -Dsonar.projectKey=chatbot-pipeline \
                                               -Dsonar.sources=. \
                                               -Dsonar.host.url=http://3.111.230.40:9000 \
                                               -Dsonar.login=${SONAR_TOKEN} \
                                                -X
					     """
                               }
                       }
           }
        }
        stage('Build Docker Image') {
            steps {
                echo 'Starting to build Docker image'
                sh 'docker build -t $IMAGE_NAME:$BUILD_NUMBER .'
	    }
	}

	    stage('Trivy Scan'){
			steps {
				sh 'trivy --severity HIGH,CRITICAL --no-progress --format table -o trivy-report.html image $IMAGE_NAME:$BUILD_NUMBER'
			}
		}

	    stage('push Docker Image to ECR Repository') {
            steps {
                sh 'aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $IMAGE_NAME'
                sh 'docker push $IMAGE_NAME:$BUILD_NUMBER'
                echo '#### Successfully built Docker image ####'
            }
        }   
	    
        stage('Deploy Docker Container') {
            steps {
                script {
                    echo 'Stopping and removing the existing container if it exists'
                    sh """
                        if [ \$(docker ps -q -f name=$CONTAINER_NAME) ]; then
                            docker stop $CONTAINER_NAME
                            docker rm -f $CONTAINER_NAME
                        fi
                    """
                    
                    echo 'Pulling the latest Docker image'
                    sh "docker pull $IMAGE_NAME:$BUILD_NUMBER"

                    echo 'Deploying the new container'
                    sh """
                        docker run -d --name $CONTAINER_NAME \\
                            -p 8000:8000 \\
                            $IMAGE_NAME:$BUILD_NUMBER
                    """
                }
                echo '#### Successfully deployed Docker container ####'
            }
        }
    }
}
    
